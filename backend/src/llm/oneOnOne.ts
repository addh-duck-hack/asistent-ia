import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { OneOnOne, type Analysis } from "@asistent-ia/schema";
import { ActionItemModel, AnalysisModel, PersonModel, ProjectModel, SessionModel, TranscriptModel } from "../models/index.js";
import { normalize, personKeys } from "../utils/people.js";
import { NonRetryableAnalysisError } from "./analyze.js";
import { getClaude } from "./client.js";
import { estimateCostUsd } from "./pricing.js";
import { getProfile, type AnalysisProfile } from "./profiles.js";
import { ONE_ON_ONE_PROMPT_VERSION, ONE_ON_ONE_SYSTEM_PROMPT } from "./prompts/oneOnOne.js";

export interface OneOnOneInput {
  personId: string;
  periodStart: Date;
  periodEnd: Date;
  body: string;
}

export interface OneOnOneOutput {
  result: OneOnOne;
  model: string;
  effort: string;
  promptVersion: string;
  usage: { inputTokens: number; outputTokens: number; costUsd: number | null };
}

const DAY = 86_400_000;
const day = (d: Date) => d.toISOString().slice(0, 10);

/**
 * Reúne las últimas `days` de una persona: sus pendientes con historial y lo
 * que se dijo de ella (resúmenes de sesión y líneas de transcripción donde se
 * le nombra). Sin transcripciones completas, para que sea barato.
 */
export async function buildOneOnOneInput(personId: string, days = 14, now = new Date()): Promise<OneOnOneInput | null> {
  const person = await PersonModel.findById(personId).lean();
  if (!person) return null;
  const periodStart = new Date(now.getTime() - days * DAY);
  const keys = personKeys(person);

  const [items, projects] = await Promise.all([
    ActionItemModel.find({
      ownerId: person._id,
      $or: [{ status: { $in: ["open", "in_progress", "blocked"] } }, { updatedAt: { $gte: periodStart } }],
    })
      .populate<{ projectId: { name: string } }>("projectId", "name")
      .sort({ createdAt: 1 })
      .limit(60)
      .lean(),
    ProjectModel.find({ members: person._id }).select({ name: 1 }).lean(),
  ]);

  const itemLines = items.map((i) => {
    const due = i.dueDate ? `, vence ${day(i.dueDate)}${i.dueDate < now && i.status !== "done" ? " (VENCIDO)" : ""}` : "";
    const history = i.history
      .slice(-3)
      .map((h) => `    · ${h.at ? day(new Date(h.at)) : ""} ${h.status ?? ""}: ${h.note ?? ""}`)
      .join("\n");
    return `- [${i.projectId?.name ?? "?"}] ${i.task} — ${i.status}${due}${history ? `\n${history}` : ""}`;
  });

  // Sesiones del periodo en sus proyectos: resumen + líneas donde se le nombra.
  const sessions = await SessionModel.find({
    projectId: { $in: projects.map((p) => p._id) },
    status: "done",
    date: { $gte: periodStart, $lte: now },
  })
    .sort({ date: 1 })
    .limit(40)
    .lean();
  const [analyses, transcripts] = await Promise.all([
    AnalysisModel.find({ sessionId: { $in: sessions.map((s) => s._id) } }).sort({ createdAt: 1 }).lean(),
    TranscriptModel.find({ sessionId: { $in: sessions.map((s) => s._id) } }).select({ sessionId: 1, text: 1 }).lean(),
  ]);
  const analysisBySession = new Map(analyses.map((a) => [String(a.sessionId), a.result as Analysis]));
  const textBySession = new Map(transcripts.map((t) => [String(t.sessionId), t.text]));

  const mentionBlocks: string[] = [];
  for (const s of sessions) {
    const lines = (textBySession.get(String(s._id)) ?? "")
      .split("\n")
      .filter((line) => {
        const words = new Set(normalize(line).split(/[^\p{L}\p{N}]+/u));
        return keys.some((k) => k.split(" ").every((w) => words.has(w)));
      })
      .slice(0, 6);
    const a = analysisBySession.get(String(s._id));
    const mentionedInAnalysis =
      a && keys.some((k) => normalize(JSON.stringify([a.action_items, a.blockers, a.decisions, a.team_signals])).includes(k));
    if (lines.length === 0 && !mentionedInAnalysis) continue;
    mentionBlocks.push(
      [`### ${s.title} (${day(s.date)})`, a?.summary.executive ?? "", ...lines.map((l) => `> ${l}`)].filter(Boolean).join("\n"),
    );
  }

  const body = [
    `<persona>\nNombre: ${person.name}${person.aliases?.length ? ` (también: ${person.aliases.join(", ")})` : ""}${person.role ? `\nRol: ${person.role}` : ""}\nProyectos: ${projects.map((p) => p.name).join(", ") || "ninguno"}\n</persona>`,
    `<periodo>${day(periodStart)} a ${day(now)}</periodo>`,
    `<pendientes>\n${itemLines.join("\n") || "Ninguno."}\n</pendientes>`,
    `<menciones>\n${mentionBlocks.join("\n\n") || "No se le mencionó en sesiones del periodo."}\n</menciones>`,
    "Prepara el 1:1 con esta persona.",
  ].join("\n\n");

  return { personId: String(person._id), periodStart, periodEnd: now, body };
}

export async function generateOneOnOne(
  input: OneOnOneInput,
  client: Anthropic = getClaude(),
  profile: AnalysisProfile = getProfile("standard"),
): Promise<OneOnOneOutput> {
  let message;
  try {
    message = await client.beta.messages
      .stream({
        model: profile.model,
        max_tokens: 32000,
        thinking: { type: "adaptive" },
        output_config: { effort: profile.effort, format: betaZodOutputFormat(OneOnOne) },
        ...(profile.model.startsWith("claude-haiku")
          ? {}
          : { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }),
        system: [{ type: "text", text: ONE_ON_ONE_SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
        messages: [{ role: "user", content: input.body }],
      })
      .finalMessage();
  } catch (err) {
    if (err instanceof Anthropic.BadRequestError || err instanceof Anthropic.AuthenticationError) {
      throw new NonRetryableAnalysisError(`Claude ${err.status}: ${err.message}`);
    }
    throw err;
  }
  if (message.stop_reason === "refusal") throw new NonRetryableAnalysisError("Claude rechazó la preparación del 1:1");
  if (!message.parsed_output) throw new Error("Claude no devolvió una preparación válida para el esquema");

  const u = message.usage;
  return {
    result: message.parsed_output,
    model: message.model,
    effort: profile.effort,
    promptVersion: ONE_ON_ONE_PROMPT_VERSION,
    usage: {
      inputTokens: u.input_tokens + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0),
      outputTokens: u.output_tokens,
      costUsd: estimateCostUsd(message.model, {
        inputTokens: u.input_tokens,
        outputTokens: u.output_tokens,
        cacheReadInputTokens: u.cache_read_input_tokens ?? 0,
        cacheCreationInputTokens: u.cache_creation_input_tokens ?? 0,
      }),
    },
  };
}

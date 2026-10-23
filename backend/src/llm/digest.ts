import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { Digest, type Analysis } from "@asistent-ia/schema";
import type { Types } from "mongoose";
import { ActionItemModel, AnalysisModel, ProjectModel, SessionModel } from "../models/index.js";
import { getClaude } from "./client.js";
import { estimateCostUsd } from "./pricing.js";
import { getProfile, type AnalysisProfile } from "./profiles.js";
import { DIGEST_PROMPT_VERSION, DIGEST_SYSTEM_PROMPT } from "./prompts/digest.js";
import { NonRetryableAnalysisError } from "./analyze.js";

export interface DigestInput {
  projectId: string;
  projectName: string;
  periodStart: Date;
  periodEnd: Date;
  sessionCount: number;
  /** Texto con la semana del proyecto, listo para el mensaje. */
  body: string;
}

export interface DigestOutput {
  result: Digest;
  model: string;
  effort: string;
  promptVersion: string;
  usage: { inputTokens: number; outputTokens: number; costUsd: number | null };
}

const day = (d: Date) => d.toISOString().slice(0, 10);

/**
 * Reúne la semana de un proyecto: análisis de cada sesión (no las
 * transcripciones, para que sea barato) y el estado de los pendientes.
 * Devuelve null si no hubo sesiones analizadas en el periodo.
 */
export async function buildDigestInput(
  projectId: string | Types.ObjectId,
  periodStart: Date,
  periodEnd: Date,
): Promise<DigestInput | null> {
  const project = await ProjectModel.findById(projectId).lean();
  if (!project) return null;

  const sessions = await SessionModel.find({
    projectId,
    status: "done",
    date: { $gte: periodStart, $lte: periodEnd },
  })
    .sort({ date: 1 })
    .lean();
  if (sessions.length === 0) return null;

  const analyses = await AnalysisModel.find({ sessionId: { $in: sessions.map((s) => s._id) } })
    .sort({ createdAt: 1 })
    .lean();
  const latest = new Map(analyses.map((a) => [String(a.sessionId), a.result as Analysis]));

  const [open, closed] = await Promise.all([
    ActionItemModel.find({ projectId, status: { $in: ["open", "in_progress", "blocked"] } })
      .sort({ createdAt: 1 })
      .limit(80)
      .lean(),
    ActionItemModel.find({ projectId, status: "done", updatedAt: { $gte: periodStart, $lte: periodEnd } })
      .limit(80)
      .lean(),
  ]);

  const sessionBlocks = sessions.map((s) => {
    const a = latest.get(String(s._id));
    if (!a) return `### ${s.title} (${day(s.date)})\nSin análisis.`;
    const list = (title: string, items: string[]) =>
      items.length ? `${title}:\n${items.map((i) => `- ${i}`).join("\n")}` : "";
    return [
      `### ${s.title} (${day(s.date)})`,
      a.summary.executive,
      list("Decisiones", a.decisions.map((d) => d.decision)),
      list("Bloqueos", a.blockers.map((b) => `${b.description} (${b.severity})`)),
      list("Riesgos", a.risks.map((r) => `${r.description} (${r.severity})`)),
      list("Preguntas abiertas", a.open_questions),
    ]
      .filter(Boolean)
      .join("\n");
  });

  const now = periodEnd.getTime();
  const openLines = open.map((i) => {
    const ageDays = Math.floor((now - (i.createdAt as Date).getTime()) / 86_400_000);
    const due = i.dueDate ? `, vence ${day(i.dueDate)}${i.dueDate.getTime() < now ? " (VENCIDO)" : ""}` : "";
    return `- ${i.task} — ${i.owner ?? "sin responsable"} — ${i.status}${due}, abierto hace ${ageDays} días`;
  });

  const body = [
    `<proyecto>\nNombre: ${project.name}${project.context ? `\nContexto: ${project.context}` : ""}\n</proyecto>`,
    `<periodo>${day(periodStart)} a ${day(periodEnd)} · ${sessions.length} sesiones</periodo>`,
    `<sesiones>\n${sessionBlocks.join("\n\n")}\n</sesiones>`,
    `<pendientes_abiertos>\n${openLines.join("\n") || "Ninguno."}\n</pendientes_abiertos>`,
    `<pendientes_cerrados_en_la_semana>\n${closed.map((i) => `- ${i.task} — ${i.owner ?? "sin responsable"}`).join("\n") || "Ninguno."}\n</pendientes_cerrados_en_la_semana>`,
    "Escribe el resumen semanal de este proyecto.",
  ].join("\n\n");

  return {
    projectId: String(project._id),
    projectName: project.name,
    periodStart,
    periodEnd,
    sessionCount: sessions.length,
    body,
  };
}

// Parte común de la petición (la usan la versión inmediata y la de lotes).
function baseParams(input: DigestInput, profile: AnalysisProfile) {
  return {
    model: profile.model,
    max_tokens: 32000,
    thinking: { type: "adaptive" as const },
    system: [
      { type: "text" as const, text: DIGEST_SYSTEM_PROMPT, cache_control: { type: "ephemeral" as const } },
    ],
    messages: [{ role: "user" as const, content: input.body }],
  };
}

/** Parámetros para la Batch API (no admite `fallbacks`). */
export function buildDigestBatchParams(input: DigestInput, profile: AnalysisProfile = getProfile("standard")) {
  return {
    ...baseParams(input, profile),
    output_config: { effort: profile.effort, format: zodOutputFormat(Digest) },
  };
}

/** Genera el resumen al momento (botón "Generar ahora"). */
export async function generateDigest(
  input: DigestInput,
  client: Anthropic = getClaude(),
  profile: AnalysisProfile = getProfile("standard"),
): Promise<DigestOutput> {
  let message;
  try {
    message = await client.beta.messages
      .stream({
        ...baseParams(input, profile),
        output_config: { effort: profile.effort, format: betaZodOutputFormat(Digest) },
        ...(profile.model.startsWith("claude-haiku")
          ? {}
          : { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }),
      })
      .finalMessage();
  } catch (err) {
    if (err instanceof Anthropic.BadRequestError || err instanceof Anthropic.AuthenticationError) {
      throw new NonRetryableAnalysisError(`Claude ${err.status}: ${err.message}`);
    }
    throw err;
  }
  if (message.stop_reason === "refusal") throw new NonRetryableAnalysisError("Claude rechazó el resumen");
  if (!message.parsed_output) throw new Error("Claude no devolvió un resumen válido para el esquema");

  const tokens = {
    inputTokens: message.usage.input_tokens + (message.usage.cache_read_input_tokens ?? 0) + (message.usage.cache_creation_input_tokens ?? 0),
    outputTokens: message.usage.output_tokens,
  };
  return {
    result: message.parsed_output,
    model: message.model,
    effort: profile.effort,
    promptVersion: DIGEST_PROMPT_VERSION,
    usage: {
      ...tokens,
      costUsd: estimateCostUsd(message.model, {
        inputTokens: message.usage.input_tokens,
        outputTokens: message.usage.output_tokens,
        cacheReadInputTokens: message.usage.cache_read_input_tokens ?? 0,
        cacheCreationInputTokens: message.usage.cache_creation_input_tokens ?? 0,
      }),
    },
  };
}

/** Extrae y valida el JSON de un mensaje de la Batch API (allí no hay parseo automático). */
export function parseBatchDigest(message: Anthropic.Message): Digest {
  const text = message.content.find((b): b is Anthropic.TextBlock => b.type === "text")?.text;
  if (!text) throw new Error("El resultado del lote no tiene texto");
  return Digest.parse(JSON.parse(text));
}

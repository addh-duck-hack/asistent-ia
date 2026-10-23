import Anthropic from "@anthropic-ai/sdk";
import { betaZodTool } from "@anthropic-ai/sdk/helpers/beta/zod";
import type { BetaMessage, BetaMessageParam } from "@anthropic-ai/sdk/resources/beta/messages/messages";
import { z } from "zod";
import { config } from "../config.js";
import { PersonModel, ProjectModel } from "../models/index.js";
import { NonRetryableAnalysisError } from "./analyze.js";
import { getSession, listActionItems, listSessions, searchSessions, searchTranscript } from "./askTools.js";
import { getClaude } from "./client.js";
import { estimateCostUsd } from "./pricing.js";
import { getProfile, type AnalysisProfile } from "./profiles.js";
import { ASK_PROMPT_VERSION, ASK_SYSTEM_PROMPT } from "./prompts/ask.js";

export interface AskInput {
  question: string;
  /** Turnos anteriores de la conversación (solo texto, sin las llamadas a herramientas). */
  history: { role: "user" | "assistant"; content: string }[];
  scope: { projectId?: string; personId?: string };
  now?: Date;
}

export interface AskOutput {
  answer: string;
  citations: string[];
  model: string;
  promptVersion: string;
  toolCalls: number;
  usage: { inputTokens: number; outputTokens: number; costUsd: number | null };
}

const json = (value: unknown) => JSON.stringify(value);
const DateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("YYYY-MM-DD");

export const askTools = [
  betaZodTool({
    name: "search_sessions",
    description:
      "Busca sesiones (reuniones y chats) por palabras clave en su transcripción y su resumen. Devuelve las más relevantes con su resumen ejecutivo. Úsala para preguntas sobre un tema, una decisión o un problema.",
    inputSchema: z.object({
      query: z.string().describe("Palabras clave, por ejemplo 'pagos tarjeta lanzamiento'"),
      project_id: z.string().nullish().describe("Limitar a un proyecto (id del directorio)"),
      from: DateStr.nullish(),
      to: DateStr.nullish(),
      limit: z.number().int().min(1).max(20).nullish(),
    }),
    run: async (input) => json(await searchSessions(input)),
  }),
  betaZodTool({
    name: "list_sessions",
    description: "Lista las sesiones analizadas en orden cronológico, con su resumen ejecutivo. Úsala para preguntas sobre un periodo ('¿qué pasó este mes en…?').",
    inputSchema: z.object({
      project_id: z.string().nullish(),
      from: DateStr.nullish(),
      to: DateStr.nullish(),
      limit: z.number().int().min(1).max(40).nullish(),
    }),
    run: async (input) => json(await listSessions(input)),
  }),
  betaZodTool({
    name: "get_session",
    description: "Devuelve el análisis completo de una sesión (temas, decisiones, bloqueos, riesgos, preguntas abiertas) y el estado actual de sus pendientes.",
    inputSchema: z.object({ session_id: z.string() }),
    run: async ({ session_id }) => json(await getSession(session_id)),
  }),
  betaZodTool({
    name: "search_transcript",
    description: "Devuelve las líneas de la transcripción de una sesión que contienen las palabras buscadas (con una línea de contexto). Úsala solo cuando necesites lo que se dijo textualmente.",
    inputSchema: z.object({ session_id: z.string(), query: z.string() }),
    run: async ({ session_id, query }) => json(await searchTranscript(session_id, query)),
  }),
  betaZodTool({
    name: "list_action_items",
    description: "Lista pendientes con su responsable, estado, fecha límite, sesión de origen e historial reciente. Filtra por proyecto, persona (responsable), estado o fecha de última actualización.",
    inputSchema: z.object({
      project_id: z.string().nullish(),
      person_id: z.string().nullish().describe("Responsable (id del directorio)"),
      status: z.array(z.enum(["open", "in_progress", "blocked", "done"])).nullish(),
      since: DateStr.nullish().describe("Actualizados desde esta fecha"),
    }),
    run: async (input) => json(await listActionItems(input)),
  }),
];

/** Directorio de proyectos y personas, para que Claude use sus ids en las herramientas. */
export async function buildDirectory(scope: AskInput["scope"], now = new Date()) {
  const [projects, people] = await Promise.all([
    ProjectModel.find({ archived: { $ne: true } }).select({ name: 1, description: 1 }).sort({ name: 1 }).lean(),
    PersonModel.find({ active: { $ne: false } }).select({ name: 1, aliases: 1, role: 1 }).sort({ name: 1 }).lean(),
  ]);
  const scopeProject = scope.projectId && projects.find((p) => String(p._id) === scope.projectId);
  const scopePerson = scope.personId && people.find((p) => String(p._id) === scope.personId);
  return [
    "<directorio>",
    `Hoy: ${now.toISOString().slice(0, 10)}`,
    `Líder: ${config.LEADER_NAME || "el líder"}`,
    "Proyectos:",
    ...projects.map((p) => `- ${p.name} (id ${p._id})${p.description ? `: ${p.description}` : ""}`),
    "Personas:",
    ...people.map((p) => `- ${p.name} (id ${p._id})${p.aliases?.length ? `, también: ${p.aliases.join(", ")}` : ""}${p.role ? `, ${p.role}` : ""}`),
    scopeProject ? `Alcance: la conversación es sobre el proyecto ${scopeProject.name}; limita las búsquedas a su id salvo que la pregunta pida otra cosa.` : "",
    scopePerson ? `Alcance: la conversación es sobre ${scopePerson.name}; busca por su nombre y alias y usa su id en list_action_items.` : "",
    "</directorio>",
  ]
    .filter(Boolean)
    .join("\n");
}

export function extractCitations(answer: string): string[] {
  return [...new Set([...answer.matchAll(/\[\[sesion:([a-f\d]{24})\]\]/gi)].map((m) => m[1]!.toLowerCase()))];
}

export async function answerQuestion(
  input: AskInput,
  client: Anthropic = getClaude(),
  profile: AnalysisProfile = getProfile("standard"),
): Promise<AskOutput> {
  const directory = await buildDirectory(input.scope, input.now);
  const messages: BetaMessageParam[] = [
    ...input.history.map((m) => ({ role: m.role, content: m.content })),
    // El breakpoint en la pregunta deja en caché el prefijo durante las vueltas del loop.
    { role: "user", content: [{ type: "text", text: input.question, cache_control: { type: "ephemeral" } }] },
  ];

  const runner = client.beta.messages.toolRunner({
    model: profile.model,
    max_tokens: 16000,
    max_iterations: 10,
    thinking: { type: "adaptive" },
    output_config: { effort: profile.effort },
    ...(profile.model.startsWith("claude-haiku")
      ? {}
      : { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }),
    system: [
      { type: "text", text: ASK_SYSTEM_PROMPT },
      { type: "text", text: directory, cache_control: { type: "ephemeral" } },
    ],
    tools: askTools,
    messages,
  });

  let last: BetaMessage | undefined;
  let toolCalls = 0;
  let cost: number | null = 0;
  const tokens = { inputTokens: 0, outputTokens: 0 };
  try {
    for await (const message of runner) {
      last = message;
      toolCalls += message.content.filter((b) => b.type === "tool_use").length;
      const u = message.usage;
      tokens.inputTokens += u.input_tokens + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      tokens.outputTokens += u.output_tokens;
      const c = estimateCostUsd(message.model, {
        inputTokens: u.input_tokens,
        outputTokens: u.output_tokens,
        cacheReadInputTokens: u.cache_read_input_tokens ?? 0,
        cacheCreationInputTokens: u.cache_creation_input_tokens ?? 0,
      });
      cost = cost === null || c === null ? null : cost + c;
    }
  } catch (err) {
    if (err instanceof Anthropic.BadRequestError || err instanceof Anthropic.AuthenticationError) {
      throw new NonRetryableAnalysisError(`Claude ${err.status}: ${err.message}`);
    }
    throw err;
  }
  if (!last) throw new Error("Claude no respondió");
  if (last.stop_reason === "refusal") throw new NonRetryableAnalysisError("Claude rechazó la pregunta");

  let answer = last.content
    .filter((b): b is Extract<typeof b, { type: "text" }> => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
  if (last.stop_reason === "tool_use") {
    answer = `${answer}\n\n_(La búsqueda se detuvo antes de terminar; prueba con una pregunta más concreta.)_`.trim();
  }
  return {
    answer: answer || "No pude formular una respuesta.",
    citations: extractCitations(answer),
    model: last.model,
    promptVersion: ASK_PROMPT_VERSION,
    toolCalls,
    usage: { ...tokens, costUsd: cost },
  };
}

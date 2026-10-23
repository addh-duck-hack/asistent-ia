import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { Analysis, type AnalysisDepth } from "@asistent-ia/schema";
import { getClaude } from "./client.js";
import { estimateCostUsd } from "./pricing.js";
import { getProfile, type AnalysisProfile, type Effort } from "./profiles.js";
import { ANALYSIS_PROMPT_VERSION, ANALYSIS_SYSTEM_PROMPT, DEPTH_INSTRUCTIONS } from "./prompts/analysis.js";

export interface TranscriptSegmentInput {
  startSec?: number | null;
  speaker?: string | null;
  text: string;
}

export interface AnalyzeInput {
  depth: AnalysisDepth;
  project: { name: string; description: string; context: string; members: string[] };
  session: { type: string; title: string; date: Date; participants: string[] };
  transcript: { text: string; segments: TranscriptSegmentInput[] };
  openItems: { id: string; task: string; owner?: string | null; status: string }[];
}

export interface AnalyzeOutput {
  result: Analysis;
  depth: AnalysisDepth;
  /** Modelo que respondió (puede ser el de respaldo si actuó el fallback). */
  model: string;
  effort: Effort;
  promptVersion: string;
  usage: {
    inputTokens: number;
    outputTokens: number;
    cacheReadInputTokens: number;
    cacheCreationInputTokens: number;
    costUsd: number | null;
  };
}

// Errores en los que reintentar no sirve (rechazo, petición inválida, llave
// incorrecta). El worker los marca como fallidos sin reintentar.
export class NonRetryableAnalysisError extends Error {
  override name = "NonRetryableAnalysisError";
}

const SPEAKER_LABELS: Record<string, string> = { me: "Yo", others: "Otros" };

function formatTimestamp(sec: number): string {
  const s = Math.floor(sec);
  const hh = String(Math.floor(s / 3600)).padStart(2, "0");
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return `${hh}:${mm}:${ss}`;
}

export function formatTranscript(transcript: AnalyzeInput["transcript"]): string {
  if (transcript.segments.length === 0) return transcript.text;
  return transcript.segments
    .map((seg) => {
      const ts = seg.startSec != null ? `[${formatTimestamp(seg.startSec)}] ` : "";
      const who = seg.speaker ? `${SPEAKER_LABELS[seg.speaker] ?? seg.speaker}: ` : "";
      return `${ts}${who}${seg.text}`;
    })
    .join("\n");
}

const SESSION_TYPE_LABELS: Record<string, string> = {
  meeting: "Reunión (audio transcrito)",
  teams_chat: "Chat de Microsoft Teams",
  pasted: "Texto pegado o importado",
};

// Haiku no tiene fallback del lado del servidor; Sonnet 5.5 y Opus sí.
function supportsServerFallback(model: string): boolean {
  return !model.startsWith("claude-haiku");
}

export function buildAnalysisRequest(input: AnalyzeInput, profile: AnalysisProfile = getProfile(input.depth)) {
  const { project, session, transcript, openItems } = input;

  // Bloque estable por proyecto: va antes de lo variable para que el prefijo
  // (system + proyecto) se reutilice desde la caché entre sesiones.
  const projectBlock = [
    "<proyecto>",
    `Nombre: ${project.name}`,
    project.description && `Descripción: ${project.description}`,
    project.context && `Contexto:\n${project.context}`,
    project.members.length > 0 && `Miembros: ${project.members.join(", ")}`,
    "</proyecto>",
  ]
    .filter(Boolean)
    .join("\n");

  const pending =
    openItems.length === 0
      ? "Ninguno."
      : openItems
          .map((i) => `- [${i.id}] ${i.task}${i.owner ? ` (responsable: ${i.owner})` : ""} — estado: ${i.status}`)
          .join("\n");

  const sessionBlock = [
    "<sesion>",
    `Tipo: ${SESSION_TYPE_LABELS[session.type] ?? session.type}`,
    `Título: ${session.title}`,
    `Fecha: ${session.date.toISOString().slice(0, 10)}`,
    session.participants.length > 0 && `Participantes: ${session.participants.join(", ")}`,
    DEPTH_INSTRUCTIONS[input.depth],
    "</sesion>",
    "",
    "<pendientes_abiertos>",
    pending,
    "</pendientes_abiertos>",
    "",
    "<transcripcion>",
    formatTranscript(transcript),
    "</transcripcion>",
    "",
    "Analiza esta sesión siguiendo tus instrucciones.",
  ]
    .filter((line) => line !== false)
    .join("\n");

  return {
    model: profile.model,
    // Tope de seguridad, no un ajuste de costo: solo se cobra lo generado.
    max_tokens: 64000,
    thinking: { type: "adaptive" as const },
    output_config: { effort: profile.effort, format: betaZodOutputFormat(Analysis) },
    // Si los clasificadores rechazan la petición, la API la reintenta en el
    // modelo de respaldo recomendado según la categoría del rechazo.
    ...(supportsServerFallback(profile.model)
      ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }
      : {}),
    system: [
      { type: "text" as const, text: ANALYSIS_SYSTEM_PROMPT, cache_control: { type: "ephemeral" as const } },
    ],
    messages: [
      {
        role: "user" as const,
        content: [
          { type: "text" as const, text: projectBlock, cache_control: { type: "ephemeral" as const } },
          { type: "text" as const, text: sessionBlock },
        ],
      },
    ],
  };
}

export async function analyzeTranscript(
  input: AnalyzeInput,
  client: Anthropic = getClaude(),
  profile: AnalysisProfile = getProfile(input.depth),
): Promise<AnalyzeOutput> {
  let message;
  try {
    // Streaming: una respuesta larga no choca con el timeout HTTP del SDK.
    message = await client.beta.messages.stream(buildAnalysisRequest(input, profile)).finalMessage();
  } catch (err) {
    if (
      err instanceof Anthropic.BadRequestError ||
      err instanceof Anthropic.AuthenticationError ||
      err instanceof Anthropic.PermissionDeniedError ||
      err instanceof Anthropic.NotFoundError
    ) {
      throw new NonRetryableAnalysisError(`Claude ${err.status}: ${err.message}`);
    }
    throw err;
  }

  if (message.stop_reason === "refusal") {
    const category = message.stop_details?.category ?? "sin categoría";
    throw new NonRetryableAnalysisError(`Claude rechazó el análisis (${category})`);
  }
  if (message.stop_reason === "max_tokens") {
    throw new NonRetryableAnalysisError("La respuesta de Claude se cortó por max_tokens");
  }
  if (!message.parsed_output) {
    throw new Error("Claude no devolvió un análisis válido para el esquema");
  }

  const tokens = {
    inputTokens: message.usage.input_tokens,
    outputTokens: message.usage.output_tokens,
    cacheReadInputTokens: message.usage.cache_read_input_tokens ?? 0,
    cacheCreationInputTokens: message.usage.cache_creation_input_tokens ?? 0,
  };
  return {
    result: message.parsed_output,
    depth: input.depth,
    model: message.model,
    effort: profile.effort,
    promptVersion: ANALYSIS_PROMPT_VERSION,
    usage: { ...tokens, costUsd: estimateCostUsd(message.model, tokens) },
  };
}

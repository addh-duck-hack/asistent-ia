import { z } from "zod";

// Esquema del análisis que Claude devuelve por cada sesión (reunión o chat).
// Es la fuente única: el backend lo usa como formato de salida estructurada y
// para validar; la app Mac lo replica como structs Codable.

export const Severity = z.enum(["low", "medium", "high"]);
export const Priority = z.enum(["low", "medium", "high"]);

export const Topic = z.object({
  title: z.string(),
  key_points: z.array(z.string()),
  // Marca de tiempo aproximada en la transcripción ("00:12:30"), si la hay.
  timestamp: z.string().nullable(),
});

export const Decision = z.object({
  decision: z.string(),
  decided_by: z.string().nullable(),
  context: z.string(),
});

export const ActionItemDraft = z.object({
  task: z.string(),
  owner: z.string().nullable(),
  // Fecha límite en ISO (YYYY-MM-DD) solo si se mencionó explícitamente.
  due_date: z.string().nullable(),
  priority: Priority,
});

export const Risk = z.object({
  description: z.string(),
  severity: Severity,
  mitigation: z.string().nullable(),
});

export const Blocker = z.object({
  description: z.string(),
  affected: z.string().nullable(),
  severity: Severity,
});

export const FollowUp = z.object({
  // _id del ActionItem abierto que se le pasó a Claude como contexto.
  action_item_id: z.string(),
  status: z.enum(["done", "in_progress", "blocked", "not_discussed"]),
  note: z.string(),
});

export const TeamSignals = z.object({
  workload: z.string().nullable(),
  morale: z.string().nullable(),
  dependencies: z.array(z.string()),
});

// Quién es cada voz sin identificar ("Voz 2") de una llamada separada por voz.
export const SpeakerGuess = z.object({
  label: z.string(),
  name: z.string().nullable(),
  evidence: z.string(),
});

export const Analysis = z.object({
  // Sin resumen "detallado": repetía lo que ya cubren topics y decisions y
  // era la parte más cara de la salida.
  summary: z.object({
    executive: z.string(),
  }),
  topics: z.array(Topic),
  decisions: z.array(Decision),
  action_items: z.array(ActionItemDraft),
  risks: z.array(Risk),
  blockers: z.array(Blocker),
  open_questions: z.array(z.string()),
  followups_from_previous: z.array(FollowUp),
  team_signals: TeamSignals,
  speaker_identification: z.array(SpeakerGuess),
});

export type Analysis = z.infer<typeof Analysis>;
export type ActionItemDraft = z.infer<typeof ActionItemDraft>;

export const SessionType = z.enum(["meeting", "teams_chat", "pasted"]);
export type SessionType = z.infer<typeof SessionType>;

// Nivel de análisis elegido por sesión: define modelo, effort y extensión.
// quick: dailies y chats · standard: 1:1 y seguimientos · deep: clientes, plannings.
export const AnalysisDepth = z.enum(["quick", "standard", "deep"]);
export type AnalysisDepth = z.infer<typeof AnalysisDepth>;

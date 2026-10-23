import type { Analysis } from "@asistent-ia/schema";
import { Types } from "mongoose";
import { ActionItemModel, AnalysisModel, ProjectModel, SessionModel, TranscriptModel } from "../models/index.js";
import { normalize } from "../utils/people.js";

// Consultas de solo lectura que Claude usa como herramientas en "Preguntar".
// Devuelven objetos compactos (análisis, no transcripciones completas) para
// que cada pregunta cueste centavos.

const day = (d: Date) => d.toISOString().slice(0, 10);
const oid = (id?: string | null) => (id && Types.ObjectId.isValid(id) ? new Types.ObjectId(id) : undefined);

function dateRange(from?: string | null, to?: string | null) {
  const range: { $gte?: Date; $lte?: Date } = {};
  if (from) range.$gte = new Date(`${from}T00:00:00Z`);
  if (to) range.$lte = new Date(`${to}T23:59:59Z`);
  return Object.keys(range).length ? range : undefined;
}

async function latestAnalyses(sessionIds: Types.ObjectId[]) {
  const analyses = await AnalysisModel.find({ sessionId: { $in: sessionIds } }).sort({ createdAt: 1 }).lean();
  return new Map(analyses.map((a) => [String(a.sessionId), a.result as Analysis]));
}

async function projectNames(ids: Types.ObjectId[]) {
  const projects = await ProjectModel.find({ _id: { $in: ids } }).select({ name: 1 }).lean();
  return new Map(projects.map((p) => [String(p._id), p.name]));
}

async function describeSessions(sessions: { _id: Types.ObjectId; projectId: Types.ObjectId; title: string; date: Date; type: string }[]) {
  const [analyses, names] = await Promise.all([
    latestAnalyses(sessions.map((s) => s._id)),
    projectNames([...new Set(sessions.map((s) => String(s.projectId)))].map((id) => new Types.ObjectId(id))),
  ]);
  return sessions.map((s) => ({
    session_id: String(s._id),
    title: s.title,
    date: day(s.date),
    type: s.type,
    project: names.get(String(s.projectId)) ?? null,
    summary: analyses.get(String(s._id))?.summary.executive ?? null,
  }));
}

export interface SearchInput {
  query: string;
  project_id?: string | null;
  from?: string | null;
  to?: string | null;
  limit?: number | null;
}

/** Busca sesiones por texto (transcripción y resumen), las más relevantes primero. */
export async function searchSessions(input: SearchInput) {
  const limit = Math.min(input.limit ?? 10, 20);
  const textHits = async (useText: boolean) => {
    const filter = useText
      ? { $text: { $search: input.query } }
      : { text: new RegExp(input.query.split(/\s+/).filter((w) => w.length > 3).map(escape).join("|") || escape(input.query), "i") };
    const [byTranscript, bySummary] = await Promise.all([
      TranscriptModel.find(filter, useText ? { score: { $meta: "textScore" }, sessionId: 1 } : { sessionId: 1 })
        .sort(useText ? { score: { $meta: "textScore" } } : { _id: -1 })
        .limit(100)
        .lean(),
      useText
        ? AnalysisModel.find({ $text: { $search: input.query } }, { score: { $meta: "textScore" }, sessionId: 1 })
            .sort({ score: { $meta: "textScore" } })
            .limit(100)
            .lean()
        : [],
    ]);
    // El resumen pesa el doble: si ahí aparece, es un tema central de la sesión.
    const score = new Map<string, number>();
    for (const t of byTranscript) score.set(String(t.sessionId), (score.get(String(t.sessionId)) ?? 0) + ((t as { score?: number }).score ?? 1));
    for (const a of bySummary) score.set(String(a.sessionId), (score.get(String(a.sessionId)) ?? 0) + 2 * ((a as { score?: number }).score ?? 1));
    return score;
  };

  // El índice de texto en español maneja plurales y acentos; si no encuentra
  // nada (palabras cortas o nombres raros), se intenta con una regex.
  let score = await textHits(true);
  if (score.size === 0) score = await textHits(false);

  const date = dateRange(input.from, input.to);
  const sessions = await SessionModel.find({
    _id: { $in: [...score.keys()].map((id) => new Types.ObjectId(id)) },
    status: "done",
    ...(oid(input.project_id) ? { projectId: oid(input.project_id) } : {}),
    ...(date ? { date } : {}),
  }).lean();
  sessions.sort((a, b) => (score.get(String(b._id)) ?? 0) - (score.get(String(a._id)) ?? 0) || b.date.getTime() - a.date.getTime());
  return describeSessions(sessions.slice(0, limit));
}

/** Sesiones en orden cronológico (para "¿qué pasó este mes en…?"). */
export async function listSessions(input: { project_id?: string | null; from?: string | null; to?: string | null; limit?: number | null }) {
  const date = dateRange(input.from, input.to);
  const sessions = await SessionModel.find({
    status: "done",
    ...(oid(input.project_id) ? { projectId: oid(input.project_id) } : {}),
    ...(date ? { date } : {}),
  })
    .sort({ date: -1 })
    .limit(Math.min(input.limit ?? 20, 40))
    .lean();
  return describeSessions(sessions.reverse());
}

/** El análisis completo de una sesión y el estado actual de sus pendientes. */
export async function getSession(sessionId: string) {
  const id = oid(sessionId);
  const session = id ? await SessionModel.findById(id).lean() : null;
  if (!session) return { error: "No existe una sesión con ese id." };
  const [analyses, names, items] = await Promise.all([
    latestAnalyses([session._id]),
    projectNames([session.projectId]),
    ActionItemModel.find({ sessionId: session._id }).lean(),
  ]);
  const a = analyses.get(String(session._id));
  return {
    session_id: String(session._id),
    title: session.title,
    date: day(session.date),
    type: session.type,
    project: names.get(String(session.projectId)) ?? null,
    participants: session.participants,
    analysis: a
      ? {
          summary: a.summary.executive,
          topics: a.topics.map((t) => ({ title: t.title, key_points: t.key_points })),
          decisions: a.decisions,
          blockers: a.blockers,
          risks: a.risks,
          open_questions: a.open_questions,
        }
      : null,
    action_items: items.map((i) => ({ task: i.task, owner: i.owner ?? null, status: i.status, due: i.dueDate ? day(i.dueDate) : null })),
  };
}

/** Líneas de la transcripción que contienen las palabras buscadas, con una línea de contexto. */
export async function searchTranscript(sessionId: string, query: string) {
  const id = oid(sessionId);
  const t = id ? await TranscriptModel.findOne({ sessionId: id }).select({ text: 1 }).lean() : null;
  if (!t) return { error: "La sesión no tiene transcripción." };
  const words = normalize(query).split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 2);
  const lines = t.text.split("\n");
  const hits = new Set<number>();
  lines.forEach((line, i) => {
    const n = normalize(line);
    if (words.some((w) => n.includes(w))) [i - 1, i, i + 1].forEach((j) => j >= 0 && j < lines.length && hits.add(j));
  });
  const picked = [...hits].sort((a, b) => a - b).slice(0, 30);
  return { lines: picked.map((i) => lines[i]), truncated: hits.size > picked.length };
}

/** Pendientes con su estado, responsable e historial reciente. */
export async function listActionItems(input: {
  project_id?: string | null;
  person_id?: string | null;
  status?: ("open" | "in_progress" | "blocked" | "done")[] | null;
  since?: string | null;
}) {
  const since = dateRange(input.since);
  const items = await ActionItemModel.find({
    ...(oid(input.project_id) ? { projectId: oid(input.project_id) } : {}),
    ...(oid(input.person_id) ? { ownerId: oid(input.person_id) } : {}),
    ...(input.status?.length ? { status: { $in: input.status } } : {}),
    ...(since ? { updatedAt: since } : {}),
  })
    .populate<{ sessionId: { _id: Types.ObjectId; title: string; date: Date } | null }>("sessionId", "title date")
    .populate<{ projectId: { name: string } | null }>("projectId", "name")
    .sort({ updatedAt: -1 })
    .limit(50)
    .lean();
  return items.map((i) => ({
    task: i.task,
    owner: i.owner ?? null,
    status: i.status,
    priority: i.priority,
    due: i.dueDate ? day(i.dueDate) : null,
    project: i.projectId?.name ?? null,
    created: day(i.createdAt as Date),
    session: i.sessionId ? { session_id: String(i.sessionId._id), title: i.sessionId.title, date: day(i.sessionId.date) } : null,
    history: i.history.slice(-3).map((h) => ({ date: h.at ? day(new Date(h.at)) : null, status: h.status ?? null, note: h.note ?? null })),
  }));
}

function escape(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

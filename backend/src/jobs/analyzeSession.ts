import {
  ActionItemModel,
  AnalysisModel,
  ProjectModel,
  SessionModel,
  TranscriptModel,
} from "../models/index.js";
import type { Types } from "mongoose";
import type { Analysis } from "@asistent-ia/schema";
import { analyzeTranscript, type AnalyzeInput, type AnalyzeOutput } from "../llm/analyze.js";
import { buildOwnerResolver } from "../utils/people.js";

type Analyzer = (input: AnalyzeInput) => Promise<AnalyzeOutput>;

function parseDueDate(value: string | null): Date | undefined {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined;
  const d = new Date(`${value}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? undefined : d;
}

const FOLLOWUP_STATUS = { done: "done", in_progress: "in_progress", blocked: "blocked" } as const;

/**
 * Aplica lo que Claude detectó sobre pendientes de sesiones anteriores: cambia
 * su estado y deja una nota en el historial. Solo acepta ids que se le pasaron
 * como contexto (ignora ids inventados) y omite los "not_discussed".
 */
export async function applyFollowups(
  sessionId: Types.ObjectId,
  followups: Analysis["followups_from_previous"],
  allowedIds: Set<string>,
) {
  for (const f of followups) {
    if (f.status === "not_discussed" || !allowedIds.has(f.action_item_id)) continue;
    // Idempotente al re-analizar: reemplaza la nota previa de esta misma sesión.
    await ActionItemModel.updateOne({ _id: f.action_item_id }, { $pull: { history: { sessionId } } });
    await ActionItemModel.updateOne(
      { _id: f.action_item_id },
      {
        $set: { status: FOLLOWUP_STATUS[f.status] },
        $push: { history: { sessionId, status: FOLLOWUP_STATUS[f.status], note: f.note, at: new Date() } },
      },
    );
  }
}

export async function runAnalyzeSession(sessionId: string, analyze: Analyzer = analyzeTranscript) {
  const session = await SessionModel.findById(sessionId);
  if (!session) return; // se borró antes de procesarse

  session.status = "analyzing";
  session.error = undefined;
  await session.save();

  try {
    const [transcript, project, openItems] = await Promise.all([
      TranscriptModel.findOne({ sessionId }).lean(),
      ProjectModel.findById(session.projectId)
        .populate<{ members: { name: string; aliases: string[]; active?: boolean }[] }>("members")
        .lean(),
      ActionItemModel.find({
        projectId: session.projectId,
        sessionId: { $ne: session._id },
        status: { $in: ["open", "in_progress", "blocked"] },
      })
        .sort({ createdAt: -1 })
        .limit(50)
        .lean(),
    ]);
    if (!transcript) throw new Error("La sesión no tiene transcripción");
    if (!project) throw new Error("El proyecto de la sesión ya no existe");

    const output = await analyze({
      depth: session.depth ?? "standard",
      project: {
        name: project.name,
        description: project.description ?? "",
        context: project.context ?? "",
        members: project.members
          .filter((m) => m.active !== false)
          .map((m) => ({ name: m.name, aliases: m.aliases ?? [] })),
      },
      session: {
        type: session.type,
        title: session.title,
        date: session.date,
        participants: session.participants,
      },
      transcript: { text: transcript.text, segments: transcript.segments.map((s) => ({ ...s, text: s.text })) },
      openItems: openItems.map((i) => ({
        id: String(i._id),
        task: i.task,
        owner: i.owner,
        status: i.status,
      })),
    });

    const { result } = output;
    await AnalysisModel.create({
      sessionId: session._id,
      result,
      summaryText: result.summary.executive,
      depth: output.depth,
      model: output.model,
      effort: output.effort,
      promptVersion: output.promptVersion,
      usage: output.usage,
    });

    await applyFollowups(session._id, result.followups_from_previous, new Set(openItems.map((i) => String(i._id))));

    // Al re-analizar, se reemplazan los pendientes que esta sesión creó y que
    // nadie ha tocado todavía.
    await ActionItemModel.deleteMany({ sessionId: session._id, status: "open", history: { $size: 0 } });
    const resolveOwner = await buildOwnerResolver();
    if (result.action_items.length > 0) {
      await ActionItemModel.insertMany(
        result.action_items.map((a) => ({
          projectId: session.projectId,
          sessionId: session._id,
          task: a.task,
          owner: a.owner ?? undefined,
          ownerId: resolveOwner(a.owner),
          dueDate: parseDueDate(a.due_date),
          priority: a.priority,
        })),
      );
    }

    session.status = "done";
    await session.save();
    console.log(
      `[analyze] ${sessionId} listo (${output.depth}, ${output.model}/${output.effort}) — in ${output.usage.inputTokens}, out ${output.usage.outputTokens}, cache ${output.usage.cacheReadInputTokens}, ≈ $${output.usage.costUsd ?? "?"}`,
    );
  } catch (err) {
    session.status = "failed";
    session.error = err instanceof Error ? err.message : String(err);
    await session.save();
    throw err; // Agenda decide si reintenta (ver worker.ts)
  }
}

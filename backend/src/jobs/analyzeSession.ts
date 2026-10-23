import {
  ActionItemModel,
  AnalysisModel,
  PersonModel,
  ProjectModel,
  SessionModel,
  TranscriptModel,
} from "../models/index.js";
import { analyzeTranscript, type AnalyzeInput, type AnalyzeOutput } from "../llm/analyze.js";

type Analyzer = (input: AnalyzeInput) => Promise<AnalyzeOutput>;

function normalize(s: string): string {
  return s.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase().trim();
}

// Mapea el responsable que escribió Claude ("Juan", "JP") a una Person por
// nombre o alias. Si hay ambigüedad o no hay coincidencia, queda sin ownerId.
async function buildOwnerResolver() {
  const people = await PersonModel.find().lean();
  const index = new Map<string, string[]>();
  for (const p of people) {
    for (const key of [p.name, p.name.split(/\s+/)[0] ?? "", ...(p.aliases ?? [])]) {
      if (!key) continue;
      const k = normalize(key);
      index.set(k, [...new Set([...(index.get(k) ?? []), String(p._id)])]);
    }
  }
  return (owner: string | null) => {
    if (!owner) return undefined;
    const ids = index.get(normalize(owner));
    return ids?.length === 1 ? ids[0] : undefined;
  };
}

function parseDueDate(value: string | null): Date | undefined {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined;
  const d = new Date(`${value}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? undefined : d;
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
      ProjectModel.findById(session.projectId).populate<{ members: { name: string }[] }>("members").lean(),
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
        members: project.members.map((m) => m.name),
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

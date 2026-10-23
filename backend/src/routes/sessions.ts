import { Router } from "express";
import { z } from "zod";
import { AnalysisDepth, SessionType } from "@asistent-ia/schema";
import {
  ActionItemModel,
  AnalysisModel,
  ProjectModel,
  SessionModel,
  TranscriptModel,
} from "../models/index.js";
import { enqueueAnalysis } from "../jobs/queue.js";
import { parseVtt } from "../utils/vtt.js";

export const sessionsRouter = Router();

const Segment = z.object({
  startSec: z.number().nonnegative().optional(),
  endSec: z.number().nonnegative().optional(),
  speaker: z.string().optional(),
  text: z.string().min(1),
});

const CreateSession = z.object({
  projectId: z.string().regex(/^[a-f\d]{24}$/i, "projectId inválido"),
  type: SessionType,
  title: z.string().trim().min(1),
  date: z.coerce.date(),
  durationSec: z.number().int().nonnegative().optional(),
  participants: z.array(z.string().trim().min(1)).optional(),
  depth: AnalysisDepth.default("standard"),
  transcript: z.object({
    // text: texto plano; vtt: contenido de un .vtt; segments: lo manda la app
    // Mac tras transcribir el audio localmente.
    format: z.enum(["text", "vtt", "segments"]).default("text"),
    content: z.string().optional(),
    segments: z.array(Segment).optional(),
    language: z.string().default("es"),
  }),
});

function buildTranscript(t: z.infer<typeof CreateSession>["transcript"]) {
  if (t.format === "segments") {
    if (!t.segments?.length) throw new z.ZodError([{ code: "custom", path: ["transcript", "segments"], message: "Faltan segmentos", input: t }]);
    return { segments: t.segments, text: t.segments.map((s) => s.text).join("\n") };
  }
  const content = t.content?.trim();
  if (!content) throw new z.ZodError([{ code: "custom", path: ["transcript", "content"], message: "Falta el contenido", input: t }]);
  if (t.format === "vtt") {
    const segments = parseVtt(content);
    if (segments.length === 0) throw new z.ZodError([{ code: "custom", path: ["transcript", "content"], message: "El VTT no tiene cues", input: t }]);
    return { segments, text: segments.map((s) => (s.speaker ? `${s.speaker}: ${s.text}` : s.text)).join("\n") };
  }
  return { segments: [], text: content };
}

sessionsRouter.post("/", async (req, res) => {
  const body = CreateSession.parse(req.body);
  if (!(await ProjectModel.exists({ _id: body.projectId }))) {
    res.status(404).json({ error: "project_not_found" });
    return;
  }
  const transcript = buildTranscript(body.transcript);

  // Si no se mandan participantes, se toman los hablantes del VTT.
  const speakers = [...new Set(transcript.segments.map((s) => s.speaker).filter((s): s is string => !!s && s !== "me" && s !== "others"))];

  const session = await SessionModel.create({
    projectId: body.projectId,
    type: body.type,
    title: body.title,
    date: body.date,
    durationSec: body.durationSec,
    participants: body.participants ?? speakers,
    depth: body.depth,
  });
  await TranscriptModel.create({ sessionId: session._id, ...transcript, language: body.transcript.language });
  await enqueueAnalysis(String(session._id));

  res.status(201).json(session);
});

sessionsRouter.get("/:id", async (req, res) => {
  const session = await SessionModel.findById(req.params.id).lean();
  if (!session) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  const [transcript, analysis, actionItems] = await Promise.all([
    TranscriptModel.findOne({ sessionId: session._id }).lean(),
    AnalysisModel.findOne({ sessionId: session._id }).sort({ createdAt: -1 }).lean(),
    ActionItemModel.find({ sessionId: session._id }).sort({ createdAt: 1 }).lean(),
  ]);
  res.json({ session, transcript, analysis, actionItems });
});

// Permite re-analizar con otro nivel (por ejemplo, subir a "deep").
const Reanalyze = z.object({ depth: AnalysisDepth.optional() });

sessionsRouter.post("/:id/reanalyze", async (req, res) => {
  const { depth } = Reanalyze.parse(req.body ?? {});
  const session = await SessionModel.findByIdAndUpdate(
    req.params.id,
    { status: "pending", ...(depth ? { depth } : {}), $unset: { error: 1 } },
    { returnDocument: "after" },
  );
  if (!session) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  await enqueueAnalysis(String(session._id));
  res.status(202).json(session);
});

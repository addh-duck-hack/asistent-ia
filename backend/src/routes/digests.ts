import { Router } from "express";
import { z } from "zod";
import { buildDigestInput, generateDigest } from "../llm/digest.js";
import { DigestModel } from "../models/index.js";

// Montado en /api/projects/:projectId/digests
export const digestsRouter = Router({ mergeParams: true });

digestsRouter.get("/", async (req, res) => {
  const { projectId } = req.params as { projectId: string };
  res.json(await DigestModel.find({ projectId }).sort({ periodEnd: -1 }).limit(26).lean());
});

const Generate = z.object({ days: z.number().int().min(1).max(31).default(7) });

// "Generar ahora": llamada inmediata (no Batch API), tarda unos segundos.
digestsRouter.post("/", async (req, res) => {
  const { projectId } = req.params as { projectId: string };
  const { days } = Generate.parse(req.body ?? {});
  const periodEnd = new Date();
  const periodStart = new Date(periodEnd.getTime() - days * 86_400_000);
  const input = await buildDigestInput(projectId, periodStart, periodEnd);
  if (!input) {
    res.status(422).json({ error: "no_sessions", message: `No hay sesiones analizadas en los últimos ${days} días.` });
    return;
  }
  const out = await generateDigest(input);
  const digest = await DigestModel.create({
    projectId,
    periodStart,
    periodEnd,
    sessionCount: input.sessionCount,
    result: out.result,
    source: "manual",
    model: out.model,
    effort: out.effort,
    promptVersion: out.promptVersion,
    usage: out.usage,
  });
  res.status(201).json(digest);
});

import { Router } from "express";
import { AnalysisModel, ProjectModel, SessionModel } from "../models/index.js";
import { deleteProject } from "../utils/deletion.js";

export const projectsRouter = Router();

projectsRouter.get("/", async (req, res) => {
  const filter = req.query.archived === "true" ? {} : { archived: false };
  res.json(await ProjectModel.find(filter).sort({ name: 1 }));
});

projectsRouter.post("/", async (req, res) => {
  const { name, description, context, members } = req.body ?? {};
  res.status(201).json(await ProjectModel.create({ name, description, context, members }));
});

projectsRouter.get("/:id", async (req, res) => {
  const project = await ProjectModel.findById(req.params.id).populate("members");
  if (!project) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(project);
});

projectsRouter.patch("/:id", async (req, res) => {
  const { name, description, context, members, archived } = req.body ?? {};
  const project = await ProjectModel.findByIdAndUpdate(
    req.params.id,
    { name, description, context, members, archived },
    { returnDocument: "after", runValidators: true },
  );
  if (!project) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(project);
});

// Lista de sesiones del proyecto con el resumen ejecutivo del último análisis.
projectsRouter.get("/:id/sessions", async (req, res) => {
  const sessions = await SessionModel.find({ projectId: req.params.id }).sort({ date: -1 }).limit(200).lean();
  const analyses = await AnalysisModel.find({ sessionId: { $in: sessions.map((s) => s._id) } })
    .sort({ createdAt: 1 })
    .select({ sessionId: 1, summaryText: 1, "usage.costUsd": 1 })
    .lean();
  const latest = new Map(analyses.map((a) => [String(a.sessionId), a]));
  res.json(
    sessions.map((s) => {
      const a = latest.get(String(s._id));
      return { ...s, summary: a?.summaryText ?? null, costUsd: a?.usage?.costUsd ?? null };
    }),
  );
});

// Borra el proyecto con sus sesiones, transcripciones, análisis, pendientes y resúmenes.
projectsRouter.delete("/:id", async (req, res) => {
  const result = await deleteProject(req.params.id);
  if (result.project === 0) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(result);
});

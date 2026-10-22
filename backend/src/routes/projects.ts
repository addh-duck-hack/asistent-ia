import { Router } from "express";
import { ProjectModel } from "../models/index.js";

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

import { Router } from "express";
import { PersonModel } from "../models/index.js";

export const peopleRouter = Router();

peopleRouter.get("/", async (_req, res) => {
  res.json(await PersonModel.find().sort({ name: 1 }));
});

peopleRouter.post("/", async (req, res) => {
  const { name, email, role, aliases } = req.body ?? {};
  res.status(201).json(await PersonModel.create({ name, email, role, aliases }));
});

peopleRouter.patch("/:id", async (req, res) => {
  const { name, email, role, aliases } = req.body ?? {};
  const person = await PersonModel.findByIdAndUpdate(
    req.params.id,
    { name, email, role, aliases },
    { returnDocument: "after", runValidators: true },
  );
  if (!person) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(person);
});

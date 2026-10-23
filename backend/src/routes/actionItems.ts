import { Router } from "express";
import { z } from "zod";
import { ActionItemModel } from "../models/index.js";

export const actionItemsRouter = Router();

const Status = z.enum(["open", "in_progress", "blocked", "done"]);

const ListQuery = z.object({
  projectId: z.string().regex(/^[a-f\d]{24}$/i).optional(),
  ownerId: z.string().regex(/^[a-f\d]{24}$/i).optional(),
  // Lista separada por comas; por defecto, todo lo que no está hecho.
  status: z
    .string()
    .default("open,in_progress,blocked")
    .transform((s) => s.split(",").map((x) => Status.parse(x.trim()))),
});

// Pendientes con la sesión de origen y el proyecto; primero los que vencen antes.
actionItemsRouter.get("/", async (req, res) => {
  const q = ListQuery.parse(req.query);
  const items = await ActionItemModel.find({
    status: { $in: q.status },
    ...(q.projectId ? { projectId: q.projectId } : {}),
    ...(q.ownerId ? { ownerId: q.ownerId } : {}),
  })
    .populate("sessionId", "title date")
    .populate("projectId", "name")
    .sort({ createdAt: -1 })
    .limit(500)
    .lean();

  // Con fecha primero (la más próxima arriba), luego sin fecha.
  items.sort((a, b) => {
    if (a.dueDate && b.dueDate) return a.dueDate.getTime() - b.dueDate.getTime();
    if (a.dueDate) return -1;
    if (b.dueDate) return 1;
    return 0;
  });
  res.json(items);
});

const Patch = z
  .object({
    task: z.string().trim().min(1),
    owner: z.string().trim().nullable(),
    dueDate: z.coerce.date().nullable(),
    priority: z.enum(["low", "medium", "high"]),
    status: Status,
    note: z.string().trim().max(500),
  })
  .partial();

// Edición manual desde la app; los cambios de estado quedan en el historial.
actionItemsRouter.patch("/:id", async (req, res) => {
  const { note, owner, dueDate, ...rest } = Patch.parse(req.body ?? {});
  const item = await ActionItemModel.findById(req.params.id);
  if (!item) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  const statusChanged = rest.status !== undefined && rest.status !== item.status;
  Object.assign(item, rest);
  if (owner !== undefined) {
    item.owner = owner ?? undefined;
    item.ownerId = undefined; // el responsable escrito a mano ya no se liga a una Person
  }
  if (dueDate !== undefined) item.dueDate = dueDate ?? undefined;
  if (statusChanged || note) {
    item.history.push({ status: item.status, note: note || "Actualizado manualmente", at: new Date() });
  }
  await item.save();
  res.json(item);
});

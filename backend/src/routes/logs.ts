import { Router } from "express";
import { z } from "zod";
import { ErrorLogModel } from "../models/index.js";

export const logsRouter = Router();

const ListLogs = z.object({
  limit: z.coerce.number().int().min(1).max(1000).default(200),
  sessionId: z.string().regex(/^[a-f\d]{24}$/i).optional(),
  unresolved: z.enum(["true", "false"]).optional(),
});

// Historial de errores, del más reciente al más antiguo.
logsRouter.get("/", async (req, res) => {
  const q = ListLogs.parse(req.query);
  const filter = {
    ...(q.sessionId ? { sessionId: q.sessionId } : {}),
    ...(q.unresolved === "true" ? { resolvedAt: null } : {}),
  };
  res.json(await ErrorLogModel.find(filter).sort({ createdAt: -1 }).limit(q.limit).lean());
});

// Vacía el historial; con ?resolved=true solo borra los ya resueltos.
logsRouter.delete("/", async (req, res) => {
  const filter = req.query.resolved === "true" ? { resolvedAt: { $ne: null } } : {};
  const r = await ErrorLogModel.deleteMany(filter);
  res.json({ deleted: r.deletedCount });
});

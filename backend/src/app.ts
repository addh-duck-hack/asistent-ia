import express, { type NextFunction, type Request, type Response } from "express";
import mongoose from "mongoose";
import { ZodError } from "zod";
import { requireToken } from "./middleware/auth.js";
import { projectsRouter } from "./routes/projects.js";
import { peopleRouter } from "./routes/people.js";
import { sessionsRouter } from "./routes/sessions.js";
import { actionItemsRouter } from "./routes/actionItems.js";
import { digestsRouter } from "./routes/digests.js";
import { ALL_DEPTHS, getProfile } from "./llm/profiles.js";

export function createApp() {
  const app = express();
  app.disable("x-powered-by");
  // NPM termina TLS y reenvía; confiar en su X-Forwarded-*.
  app.set("trust proxy", 1);
  // Transcripciones de reuniones largas: coincide con client_max_body_size en NPM.
  app.use(express.json({ limit: "50mb" }));

  app.get("/health", (_req, res) => {
    const mongoOk = mongoose.connection.readyState === 1;
    res.status(mongoOk ? 200 : 503).json({ ok: mongoOk });
  });

  app.use("/api", requireToken);
  app.use("/api/projects", projectsRouter);
  app.use("/api/people", peopleRouter);
  app.use("/api/sessions", sessionsRouter);
  app.use("/api/action-items", actionItemsRouter);
  app.use("/api/projects/:projectId/digests", digestsRouter);
  // La app muestra qué modelo usa cada nivel (configurable en backend/.env).
  app.get("/api/analysis-profiles", (_req, res) => {
    res.json(ALL_DEPTHS.map(getProfile));
  });

  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof ZodError) {
      res.status(400).json({ error: "invalid_body", issues: err.issues });
      return;
    }
    if (err instanceof mongoose.Error.ValidationError || err instanceof mongoose.Error.CastError) {
      res.status(400).json({ error: err.message });
      return;
    }
    console.error(err);
    res.status(500).json({ error: "internal_error" });
  });

  return app;
}

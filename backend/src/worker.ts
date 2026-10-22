import { exponential } from "agenda";
import { config } from "./config.js";
import { connectMongo } from "./db.js";
import { agenda } from "./jobs/agenda.js";
import { ANALYZE_SESSION_JOB, type AnalyzeSessionJobData } from "./jobs/queue.js";
import { runAnalyzeSession } from "./jobs/analyzeSession.js";
import { NonRetryableAnalysisError } from "./llm/analyze.js";

await connectMongo();

const retryTransient = exponential({ delay: 60_000, maxRetries: 3, jitter: 0.2 });

agenda.define<AnalyzeSessionJobData>(
  ANALYZE_SESSION_JOB,
  async (job) => {
    await runAnalyzeSession(job.attrs.data.sessionId);
  },
  {
    // Un análisis largo puede tardar varios minutos.
    lockLifetime: 15 * 60_000,
    concurrency: 2,
    // Rechazos o peticiones inválidas no se arreglan reintentando.
    backoff: (ctx) => (ctx.error instanceof NonRetryableAnalysisError ? null : retryTransient(ctx)),
  },
);

// Fase 3: agenda.define("weekly-digest", ...)

await agenda.start();
console.log("[worker] agenda iniciada");

if (config.SCHEDULER_ENABLED) {
  // Fase 3: await agenda.every("0 8 * * 1", "weekly-digest");
  console.log("[worker] tareas programadas habilitadas");
}

async function shutdown() {
  await agenda.stop();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

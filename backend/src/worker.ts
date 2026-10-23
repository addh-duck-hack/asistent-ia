import { exponential } from "agenda";
import { config } from "./config.js";
import { connectMongo } from "./db.js";
import { agenda } from "./jobs/agenda.js";
import { ANALYZE_SESSION_JOB, type AnalyzeSessionJobData } from "./jobs/queue.js";
import { runAnalyzeSession } from "./jobs/analyzeSession.js";
import { NonRetryableAnalysisError } from "./llm/analyze.js";
import { POLL_DIGEST_BATCHES_JOB, WEEKLY_DIGEST_JOB, pollDigestBatches, runWeeklyDigest } from "./jobs/digest.js";

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

agenda.define(WEEKLY_DIGEST_JOB, async () => {
  await runWeeklyDigest();
});
agenda.define(POLL_DIGEST_BATCHES_JOB, async () => {
  await pollDigestBatches();
});

await agenda.start();
console.log("[worker] agenda iniciada");

if (config.SCHEDULER_ENABLED) {
  await agenda.every("0 8 * * 1", WEEKLY_DIGEST_JOB, undefined, { timezone: config.DIGEST_TIMEZONE, skipImmediate: true });
  await agenda.every("5 minutes", POLL_DIGEST_BATCHES_JOB);
  console.log(`[worker] tareas programadas: resumen semanal lunes 8:00 (${config.DIGEST_TIMEZONE})`);
}

async function shutdown() {
  await agenda.stop();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

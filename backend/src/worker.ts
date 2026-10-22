import { config } from "./config.js";
import { connectMongo } from "./db.js";
import { agenda } from "./jobs/agenda.js";

await connectMongo();

// Fase 1: agenda.define("analyze-session", ...)
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

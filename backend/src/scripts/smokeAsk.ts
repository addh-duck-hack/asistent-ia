// Prueba real de "Preguntar" contra tus datos en Mongo y la API de Claude
// (no guarda la conversación):
//   docker compose exec worker node dist/scripts/smokeAsk.js "¿Qué está bloqueando a Tavo?"
import mongoose from "mongoose";
import { connectMongo } from "../db.js";
import { answerQuestion } from "../llm/ask.js";

const question = process.argv.slice(2).join(" ") || "¿Qué decisiones se tomaron en las últimas dos semanas?";

await connectMongo();
try {
  const started = Date.now();
  const out = await answerQuestion({ question, history: [], scope: {} });
  console.log(`\n${out.answer}\n`);
  console.log(
    `${out.model} · ${out.toolCalls} búsquedas · ${out.usage.inputTokens} tokens de entrada, ${out.usage.outputTokens} de salida · ` +
      `≈ $${out.usage.costUsd?.toFixed(4) ?? "?"} · ${((Date.now() - started) / 1000).toFixed(1)} s · ${out.citations.length} sesiones citadas`,
  );
} finally {
  await mongoose.disconnect();
}

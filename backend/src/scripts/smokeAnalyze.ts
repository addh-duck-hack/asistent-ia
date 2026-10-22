// Prueba real contra la API de Claude, sin tocar Mongo:
//   docker compose exec worker node dist/scripts/smokeAnalyze.js
// Corre el mismo análisis dos veces; en la segunda, cache_read debe ser > 0.
import { analyzeTranscript, type AnalyzeInput } from "../llm/analyze.js";

const input: AnalyzeInput = {
  project: {
    name: "Portal de clientes",
    description: "Portal web donde los clientes consultan pedidos y pagan facturas",
    context: "Stack: React + Node/Express + MongoDB. Pagos con Stripe. Lanzamiento de pagos previsto para fin de mes.",
    members: ["Ana López", "Carlos Ruiz", "María Gómez"],
  },
  session: { type: "meeting", title: "Daily", date: new Date(), participants: ["Ana López", "Carlos Ruiz", "María Gómez"] },
  transcript: {
    text: "",
    segments: [
      { startSec: 0, speaker: "me", text: "Buenos días. Carlos, ¿cómo va el endpoint de pagos?" },
      { startSec: 6, speaker: "Carlos Ruiz", text: "Ya quedó, pero me faltan los tests de integración con Stripe. Los termino el jueves." },
      { startSec: 15, speaker: "me", text: "Va. María, ¿y el diseño del checkout?" },
      { startSec: 19, speaker: "María Gómez", text: "Estoy bloqueada, sigo sin acceso a la cuenta de Stripe de pruebas. Lo pedí hace una semana." },
      { startSec: 27, speaker: "me", text: "Ok, yo hablo hoy con infraestructura para que te den acceso. Si no sale esta semana, movemos el lanzamiento." },
      { startSec: 36, speaker: "Ana López", text: "Ojo que el equipo de facturación también depende de esto, ya preguntaron dos veces." },
      { startSec: 42, speaker: "me", text: "Entonces decidimos: el lanzamiento sigue para el 30 mientras María tenga acceso antes del viernes." },
    ],
  },
  openItems: [],
};

for (const run of [1, 2]) {
  const started = Date.now();
  const out = await analyzeTranscript(input);
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  console.log(`\n=== Corrida ${run} (${secs}s, modelo ${out.model}) ===`);
  console.log("usage:", out.usage);
  if (run === 1) console.log(JSON.stringify(out.result, null, 2));
}

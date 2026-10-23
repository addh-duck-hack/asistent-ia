// Prueba real contra la API de Claude, sin tocar Mongo:
//   docker compose exec worker node dist/scripts/smokeAnalyze.js [quick|standard|deep] [daily]
// Con "daily" usa una ronda grabada (solo "Yo"/"Otros") para probar que los
// responsables se infieren por turnos.
// Corre el mismo análisis dos veces; en la segunda, cache_read debe ser > 0
// si el prefijo fijo alcanza el mínimo cacheable del modelo.
import { AnalysisDepth } from "@asistent-ia/schema";
import { analyzeTranscript, type AnalyzeInput } from "../llm/analyze.js";

const depth = AnalysisDepth.parse(process.argv[2] ?? "quick");
const dailySample = process.argv[3] === "daily";

// Ronda de daily como sale de una grabación: las respuestas no dicen el nombre.
const DAILY_SEGMENTS = [
  { startSec: 0, speaker: "me", text: "Buenos días a todos, vamos con la ronda. Octavio, buenos días, ¿qué tienes hoy?" },
  { startSec: 6, speaker: "others", text: "Buenos días. Hoy voy a estar con los crash de Panda, ya tengo ubicados los dos más frecuentes." },
  { startSec: 14, speaker: "me", text: "Perfecto. Ana, ¿cómo vas con los deep links?" },
  { startSec: 18, speaker: "others", text: "Ya quedaron en iOS, en Android me falta probar, lo termino mañana." },
  { startSec: 26, speaker: "me", text: "Va. Carlos, ¿tú?" },
  { startSec: 28, speaker: "others", text: "Yo sigo bloqueado con los servicios de NPS, Delphi no los ha entregado." },
  { startSec: 35, speaker: "me", text: "Ok, yo hablo hoy con Delphi para destrabar eso." },
];

const input: AnalyzeInput = {
  depth,
  project: {
    name: "Portal de clientes",
    description: "Portal web donde los clientes consultan pedidos y pagan facturas",
    context: "Stack: React + Node/Express + MongoDB. Pagos con Stripe. Lanzamiento de pagos previsto para fin de mes.",
    members: ["Ana López", "Carlos Ruiz", "María Gómez"],
  },
  session: { type: "meeting", title: "Daily", date: new Date(), participants: ["Ana López", "Carlos Ruiz", "María Gómez"] },
  transcript: {
    text: "",
    segments: dailySample ? DAILY_SEGMENTS : [
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
  console.log(`\n=== Corrida ${run} (${secs}s, ${depth}: ${out.model}/${out.effort}) ===`);
  console.log("usage:", out.usage);
  if (run === 1) console.log(JSON.stringify(out.result, null, 2));
}

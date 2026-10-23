import { afterAll, beforeAll, beforeEach, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";

vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis: vi.fn(), ANALYZE_SESSION_JOB: "analyze-session" }));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let m: typeof import("./models/index.js");

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_transcript_edit_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  m = await import("./models/index.js");
  await connectMongo();
  server = createApp().listen(0);
  const addr = server.address();
  base = `http://127.0.0.1:${typeof addr === "object" && addr ? addr.port : 0}`;
}, 120_000);

afterAll(async () => {
  server?.close();
  await mongoose.disconnect();
  await mongo?.stop();
});

beforeEach(async () => {
  await mongoose.connection.db!.dropDatabase();
});

const headers = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
const api = (path: string, method = "GET", body?: unknown) =>
  fetch(`${base}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });

const LINE = "Yo estuve trabajando en la London de Buenfin, de México, de Petco y también unos ajustes para CRM, no, para Tox, las cards de producto.";

async function recorded() {
  const project = await m.ProjectModel.create({ name: "Equipo" });
  const session = await m.SessionModel.create({ projectId: project._id, type: "meeting", title: "Cierre", date: new Date(), status: "done" });
  await m.TranscriptModel.create({
    sessionId: session._id,
    segments: [
      { startSec: 0, speaker: "Voz 1", text: LINE },
      { startSec: 9, speaker: "me", text: "Ok, lo de TOX y el tóxico de la API lo vemos mañana." },
    ],
    text: `${LINE}\nOk, lo de TOX y el tóxico de la API lo vemos mañana.`,
  });
  return { project, session };
}

it("reemplaza palabras completas sin distinguir mayúsculas, en segmentos y texto", async () => {
  const { session } = await recorded();
  const res = await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "Tox", replace: "Toks" });
  expect(res.status).toBe(200);
  const { replacements, transcript } = await res.json();
  expect(replacements).toBe(2); // "Tox" y "TOX"; "tóxico" no cambia
  expect(transcript.segments[1].text).toBe("Ok, lo de Toks y el tóxico de la API lo vemos mañana.");
  expect(transcript.text).toContain("para Toks, las cards");

  // Frases con comas y texto de reemplazo con "$" literal.
  await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "CRM, no, para", replace: "CRM, para" });
  await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "London", replace: "Landing" });
  const saved = await m.TranscriptModel.findOne({ sessionId: session._id }).lean();
  expect(saved!.segments[0]!.text).toBe(
    "Yo estuve trabajando en la Landing de Buenfin, de México, de Petco y también unos ajustes para CRM, para Toks, las cards de producto.",
  );
  const dollar = await (await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "API", replace: "$1 API" })).json();
  expect(dollar.transcript.segments[1].text).toContain("de la $1 API");

  const none = await (await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "Zzz", replace: "x" })).json();
  expect(none.replacements).toBe(0);
  expect((await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "", replace: "x" })).status).toBe(400);
  expect((await api(`/api/sessions/${"a".repeat(24)}/transcript/replace`, "POST", { find: "a", replace: "b" })).status).toBe(404);
});

it("en texto pegado (sin segmentos) reemplaza en el texto", async () => {
  const project = await m.ProjectModel.create({ name: "Equipo" });
  const session = await m.SessionModel.create({ projectId: project._id, type: "pasted", title: "Chat", date: new Date(), status: "done" });
  await m.TranscriptModel.create({ sessionId: session._id, segments: [], text: "Ana: lo de Tox va.\nLuis: Tox listo." });
  const out = await (await api(`/api/sessions/${session._id}/transcript/replace`, "POST", { find: "tox", replace: "Toks" })).json();
  expect(out.replacements).toBe(2);
  expect(out.transcript.text).toBe("Ana: lo de Toks va.\nLuis: Toks listo.");
});

it("el vocabulario del proyecto se limpia y llega a Claude", async () => {
  const created = await (await api("/api/projects", "POST", { name: "Toks", vocabulary: [" Toks ", "toks", "", "Landing", "Buen Fin"] })).json();
  expect(created.vocabulary).toEqual(["Toks", "Landing", "Buen Fin"]);
  const patched = await (await api(`/api/projects/${created._id}`, "PATCH", { vocabulary: ["Petco", "Toks", "PETCO"] })).json();
  expect(patched.vocabulary).toEqual(["Petco", "Toks"]);
  const kept = await (await api(`/api/projects/${created._id}`, "PATCH", { context: "Restaurantes" })).json();
  expect(kept.vocabulary).toEqual(["Petco", "Toks"]); // no se borra si no se manda

  const { buildAnalysisRequest } = await import("./llm/analyze.js");
  const req = buildAnalysisRequest({
    depth: "quick",
    project: { name: "Toks", description: "", context: "", vocabulary: ["Petco", "Toks"], members: [] },
    session: { type: "meeting", title: "Daily", date: new Date(), participants: [] },
    transcript: { text: "hola", segments: [] },
    openItems: [],
  });
  expect(req.messages[0]!.content[0]!.text).toContain("Vocabulario: Petco, Toks");
  const { ANALYSIS_PROMPT_VERSION, ANALYSIS_SYSTEM_PROMPT } = await import("./llm/prompts/analysis.js");
  expect(ANALYSIS_PROMPT_VERSION).toBe("analysis-v7");
  expect(ANALYSIS_SYSTEM_PROMPT).toContain("vocabulario");

  const { buildDirectory } = await import("./llm/ask.js");
  expect(await buildDirectory({})).toContain("vocabulario: Petco, Toks");
});

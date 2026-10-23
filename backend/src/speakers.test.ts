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
  process.env.MONGO_URL = mongo.getUri("asistent_ia_speakers_test");
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

it("las voces sin identificar no cuentan como participantes y se pueden renombrar", async () => {
  const project = await m.ProjectModel.create({ name: "Panda" });
  const octavio = await m.PersonModel.create({ name: "Octavio Ramírez", aliases: ["Tavo"] });
  const created = await api("/api/sessions", "POST", {
    projectId: String(project._id), type: "meeting", title: "Daily", date: "2026-10-23T15:00:00Z", depth: "quick",
    transcript: { format: "segments", segments: [
      { startSec: 0, speaker: "me", text: "Tavo, ¿qué tienes hoy?" },
      { startSec: 3, speaker: "Voz 1", text: "Los crash de Panda." },
      { startSec: 6, speaker: "Ana López", text: "Yo sigo con deep links." },
      { startSec: 9, speaker: "Voz 2", text: "Yo reviso el contrato." },
    ] },
  });
  const session = await created.json();
  expect(session.participants).toEqual(["Ana López"]);

  await m.ActionItemModel.create({ projectId: project._id, sessionId: session._id, task: "Arreglar crash", owner: "Voz 1" });
  await m.ActionItemModel.create({ projectId: project._id, sessionId: session._id, task: "Contrato", owner: "Voz 2" });

  const res = await api(`/api/sessions/${session._id}/speakers`, "PATCH", { renames: [{ from: "Voz 1", to: "Octavio Ramírez" }] });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ segments: 1, items: 1, participants: ["Ana López", "Octavio Ramírez"] });

  const t = await m.TranscriptModel.findOne({ sessionId: session._id }).lean();
  expect(t!.segments.map((s) => s.speaker)).toEqual(["me", "Octavio Ramírez", "Ana López", "Voz 2"]);
  const item = await m.ActionItemModel.findOne({ task: "Arreglar crash" }).lean();
  expect(item).toMatchObject({ owner: "Octavio Ramírez" });
  expect(String(item!.ownerId)).toBe(String(octavio._id));
  expect((await m.ActionItemModel.findOne({ task: "Contrato" }).lean())!.owner).toBe("Voz 2");

  expect((await api(`/api/sessions/${session._id}/speakers`, "PATCH", { renames: [] })).status).toBe(400);
  expect((await api(`/api/sessions/${"a".repeat(24)}/speakers`, "PATCH", { renames: [{ from: "Voz 1", to: "X" }] })).status).toBe(404);
});

it("el prompt v6 explica las voces separadas y pide speaker_identification", async () => {
  const { ANALYSIS_SYSTEM_PROMPT, ANALYSIS_PROMPT_VERSION } = await import("./llm/prompts/analysis.js");
  expect(ANALYSIS_PROMPT_VERSION).toBe("analysis-v6");
  expect(ANALYSIS_SYSTEM_PROMPT).toContain('"Voz 1", "Voz 2"');
  expect(ANALYSIS_SYSTEM_PROMPT).toContain("speaker_identification");
});

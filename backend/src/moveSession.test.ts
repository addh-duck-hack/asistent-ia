import { afterAll, beforeAll, beforeEach, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";

const enqueueAnalysis = vi.fn(async (_id: string) => {});
vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis, ANALYZE_SESSION_JOB: "analyze-session" }));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let m: typeof import("./models/index.js");

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_move_test");
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
  enqueueAnalysis.mockClear();
  await mongoose.connection.db!.dropDatabase();
});

const headers = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
const move = (id: unknown, projectId: unknown) =>
  fetch(`${base}/api/sessions/${id}/move`, { method: "POST", headers, body: JSON.stringify({ projectId }) });

it("mueve la sesión y sus pendientes, deshace sus seguimientos en el proyecto anterior y re-analiza", async () => {
  const [wrong, right] = await m.ProjectModel.create([{ name: "Panda" }, { name: "Toks" }]);
  const previous = await m.SessionModel.create({ projectId: wrong._id, type: "meeting", title: "Daily del lunes", date: new Date("2026-11-09") });
  const session = await m.SessionModel.create({ projectId: wrong._id, type: "meeting", title: "Cierre", date: new Date("2026-11-10"), status: "done" });

  const born = await m.ActionItemModel.create({ projectId: wrong._id, sessionId: session._id, task: "Subir la landing" });
  // Pendiente de Panda que esta sesión marcó como hecho por error.
  const closed = await m.ActionItemModel.create({
    projectId: wrong._id, sessionId: previous._id, task: "Arreglar crash", status: "done",
    history: [
      { sessionId: previous._id, status: "blocked", note: "Esperando logs" },
      { sessionId: session._id, status: "done", note: "Ya quedó" },
    ],
  });
  // Otro que el líder cambió a mano después: se quita la nota pero se respeta el estado.
  const edited = await m.ActionItemModel.create({
    projectId: wrong._id, sessionId: previous._id, task: "Contrato", status: "in_progress",
    history: [{ sessionId: session._id, status: "done", note: "Firmado" }],
  });

  const res = await move(session._id, String(right._id));
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body).toMatchObject({ movedItems: 1, revertedFollowups: 2 });
  expect(body.session).toMatchObject({ projectId: String(right._id), status: "pending" });
  expect(enqueueAnalysis).toHaveBeenCalledWith(String(session._id));

  expect(String((await m.ActionItemModel.findById(born._id).lean())!.projectId)).toBe(String(right._id));
  const c = (await m.ActionItemModel.findById(closed._id).lean())!;
  expect(c.status).toBe("blocked");
  expect(c.history.map((h) => h.note)).toEqual(["Esperando logs"]);
  const e = (await m.ActionItemModel.findById(edited._id).lean())!;
  expect(e.status).toBe("in_progress");
  expect(e.history).toEqual([]);
});

it("valida el proyecto y no hace nada si ya está en él", async () => {
  const project = await m.ProjectModel.create({ name: "Panda" });
  const session = await m.SessionModel.create({ projectId: project._id, type: "meeting", title: "Cierre", date: new Date(), status: "done" });

  const same = await move(session._id, String(project._id));
  expect(same.status).toBe(200);
  expect((await same.json()).session.status).toBe("done");
  expect(enqueueAnalysis).not.toHaveBeenCalled();

  expect((await move(session._id, "a".repeat(24))).status).toBe(404);
  expect((await move("a".repeat(24), String(project._id))).status).toBe(404);
  expect((await move(session._id, "nope")).status).toBe(400);
});

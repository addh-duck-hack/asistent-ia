import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";
import type Anthropic from "@anthropic-ai/sdk";
import type { OneOnOne } from "@asistent-ia/schema";

vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis: vi.fn(), ANALYZE_SESSION_JOB: "analyze-session" }));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let m: typeof import("./models/index.js");
let oneOnOne: typeof import("./llm/oneOnOne.js");

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_team_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  m = await import("./models/index.js");
  oneOnOne = await import("./llm/oneOnOne.js");
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

async function seed() {
  const project = await m.ProjectModel.create({ name: "Equipo de desarrollo" });
  const other = await m.ProjectModel.create({ name: "TOKS" });
  const session = await m.SessionModel.create({
    projectId: project._id,
    type: "meeting",
    title: "Daily",
    date: new Date(),
    status: "done",
  });
  await m.TranscriptModel.create({
    sessionId: session._id,
    text: "Yo: Tavo, buenos días, ¿qué tienes hoy?\nOtros: Hoy voy a estar con los crash de Panda.\nYo: Mañana revisamos.",
  });
  return { project, other, session };
}

describe("personas y alias", () => {
  it("al crear a Octavio con alias Tavo se ligan sus pendientes (por nombre y por alias)", async () => {
    const { project, other, session } = await seed();
    await m.ActionItemModel.create([
      { projectId: project._id, sessionId: session._id, task: "Crash de Panda", owner: "Octavio" },
      { projectId: other._id, sessionId: session._id, task: "Revisar builds", owner: "Tavo" },
      { projectId: project._id, sessionId: session._id, task: "Ajena", owner: "Ana" },
    ]);
    const r = await api("/api/people", "POST", {
      name: "Octavio Ramírez",
      aliases: ["Tavo", " tavo ", "Octavio Ramírez", ""],
      projectIds: [String(project._id), String(other._id)],
    });
    expect(r.status).toBe(201);
    const person = await r.json();
    expect(person.aliases).toEqual(["Tavo"]); // limpia vacíos, repetidos y el propio nombre
    expect(person.linkedItems).toBe(2);

    const items = await api(`/api/action-items?ownerId=${person._id}`).then((x) => x.json());
    expect(items.map((i: { task: string }) => i.task).sort()).toEqual(["Crash de Panda", "Revisar builds"]);

    const projects = await m.ProjectModel.find({ members: person._id }).lean();
    expect(projects).toHaveLength(2);

    // Quitar un proyecto lo saca de Project.members.
    await api(`/api/people/${person._id}`, "PATCH", { projectIds: [String(project._id)] });
    expect(await m.ProjectModel.countDocuments({ members: person._id })).toBe(1);
  });

  it("no liga coincidencias ambiguas (dos personas con el mismo primer nombre)", async () => {
    const { project, session } = await seed();
    await m.ActionItemModel.create({ projectId: project._id, sessionId: session._id, task: "X", owner: "Ana" });
    await api("/api/people", "POST", { name: "Ana López" });
    const second = await api("/api/people", "POST", { name: "Ana Torres" }).then((x) => x.json());
    expect(second.linkedItems).toBe(0);
    expect((await m.ActionItemModel.findOne({ task: "X" }).lean())!.ownerId).toBeDefined(); // la ligó la primera Ana
  });

  it("un alias repetido entre personas activas responde 409", async () => {
    await api("/api/people", "POST", { name: "Octavio Ramírez", aliases: ["Tavo"] });
    const r = await api("/api/people", "POST", { name: "Gustavo Pérez", aliases: ["tavo"] });
    expect(r.status).toBe(409);
    expect((await r.json()).message).toContain("Octavio Ramírez");
  });

  it("lista el equipo con contadores y oculta archivados", async () => {
    const { project, session } = await seed();
    const p = await api("/api/people", "POST", { name: "Octavio Ramírez", projectIds: [String(project._id)] }).then((x) =>
      x.json(),
    );
    const yesterday = new Date(Date.now() - 86_400_000);
    await m.ActionItemModel.create([
      { projectId: project._id, sessionId: session._id, task: "A", ownerId: p._id },
      { projectId: project._id, sessionId: session._id, task: "B", ownerId: p._id, status: "blocked" },
      { projectId: project._id, sessionId: session._id, task: "C", ownerId: p._id, dueDate: yesterday },
      { projectId: project._id, sessionId: session._id, task: "D", ownerId: p._id, status: "done" },
    ]);
    const [person] = await api("/api/people").then((x) => x.json());
    expect(person.counts).toEqual({ open: 3, blocked: 1, overdue: 1, doneWeek: 1 });
    expect(person.projects.map((x: { name: string }) => x.name)).toEqual(["Equipo de desarrollo"]);

    await api(`/api/people/${p._id}`, "PATCH", { active: false });
    expect(await api("/api/people").then((x) => x.json())).toHaveLength(0);
    expect(await api("/api/people?all=true").then((x) => x.json())).toHaveLength(1);
  });
});

describe("ficha: avance y menciones", () => {
  it("separa cerrados, asignados, estancados, bloqueados y vencidos", async () => {
    const { project, session } = await seed();
    const p = await m.PersonModel.create({ name: "Octavio Ramírez" });
    const old = new Date(Date.now() - 10 * 86_400_000);
    await m.ActionItemModel.create([
      { projectId: project._id, sessionId: session._id, task: "Nuevo", ownerId: p._id },
      { projectId: project._id, sessionId: session._id, task: "Cerrado", ownerId: p._id, status: "done" },
      { projectId: project._id, sessionId: session._id, task: "Bloqueado", ownerId: p._id, status: "blocked" },
      { projectId: project._id, sessionId: session._id, task: "Vencido", ownerId: p._id, dueDate: new Date(Date.now() - 2 * 86_400_000) },
    ]);
    // Un pendiente viejo sin cambios = estancado.
    await m.ActionItemModel.collection.insertOne({
      projectId: project._id,
      sessionId: session._id,
      task: "Viejo",
      ownerId: p._id,
      status: "open",
      priority: "medium",
      history: [],
      createdAt: old,
      updatedAt: old,
    });
    const prog = await api(`/api/people/${p._id}/progress`).then((x) => x.json());
    const tasks = (k: string) => prog[k].map((i: { task: string }) => i.task).sort();
    expect(tasks("completed")).toEqual(["Cerrado"]);
    expect(tasks("assigned")).toEqual(["Bloqueado", "Cerrado", "Nuevo", "Vencido"]);
    expect(tasks("stalled")).toEqual(["Viejo"]);
    expect(tasks("blocked")).toEqual(["Bloqueado"]);
    expect(tasks("overdue")).toEqual(["Vencido"]);
  });

  it("encuentra menciones por alias sin importar acentos ni mayúsculas, y no dentro de otras palabras", async () => {
    const { session, project } = await seed();
    const s2 = await m.SessionModel.create({ projectId: project._id, type: "pasted", title: "Chat", date: new Date(), status: "done" });
    await m.TranscriptModel.create({ sessionId: s2._id, text: "Mañana sigue la revisión." });
    const p = await m.PersonModel.create({ name: "Ana López", aliases: ["TAVO"] });
    const mentions = await api(`/api/people/${p._id}/mentions`).then((x) => x.json());
    expect(mentions).toHaveLength(1); // "Mañana" no cuenta como "Ana"
    expect(mentions[0].session._id).toBe(String(session._id));
    expect(mentions[0].snippet).toContain("Tavo, buenos días");
  });
});

describe("tareas manuales y asignación", () => {
  it("crea una tarea sin sesión y la reasigna dejando historial", async () => {
    const { project } = await seed();
    const ana = await m.PersonModel.create({ name: "Ana López" });
    const tavo = await m.PersonModel.create({ name: "Octavio Ramírez" });
    const created = await api("/api/action-items", "POST", {
      projectId: String(project._id),
      task: "Documentar el release",
      ownerId: String(ana._id),
      priority: "high",
    }).then((x) => x.json());
    expect(created).toMatchObject({ source: "manual", owner: "Ana López", priority: "high" });
    expect(created.sessionId).toBeUndefined();

    const reassigned = await api(`/api/action-items/${created._id}`, "PATCH", { ownerId: String(tavo._id) }).then((x) =>
      x.json(),
    );
    expect(reassigned).toMatchObject({ owner: "Octavio Ramírez", ownerId: String(tavo._id) });
    expect(reassigned.history.at(-1).note).toBe("Responsable: Octavio Ramírez");

    const cleared = await api(`/api/action-items/${created._id}`, "PATCH", { ownerId: null }).then((x) => x.json());
    expect(cleared.owner).toBeUndefined();

    const list = await api(`/api/action-items?projectId=${project._id}`).then((x) => x.json());
    expect(list[0].sessionId).toBeUndefined(); // manual: sin sesión de origen
    expect((await api("/api/action-items", "POST", { projectId: "0".repeat(24), task: "x" })).status).toBe(404);
  });
});

describe("preparación del 1:1", () => {
  it("arma la entrada con pendientes, historial y líneas donde se le nombra por alias", async () => {
    const { project, session } = await seed();
    await m.AnalysisModel.create({
      sessionId: session._id,
      result: {
        summary: { executive: "Daily del equipo." },
        topics: [],
        decisions: [],
        action_items: [{ task: "Crash de Panda", owner: "Octavio Ramírez", due_date: null, priority: "medium" }],
        risks: [],
        blockers: [],
        open_questions: [],
        followups_from_previous: [],
        team_signals: { workload: null, morale: null, dependencies: [] },
      },
      summaryText: "Daily del equipo.",
      model: "x",
      promptVersion: "v",
    });
    const p = await m.PersonModel.create({ name: "Octavio Ramírez", aliases: ["Tavo"], role: "iOS" });
    await m.ProjectModel.updateOne({ _id: project._id }, { $addToSet: { members: p._id } });
    await m.ActionItemModel.create({
      projectId: project._id,
      sessionId: session._id,
      task: "Crash de Panda",
      ownerId: p._id,
      status: "blocked",
      history: [{ status: "blocked", note: "Falta acceso a Crashlytics", at: new Date() }],
    });

    const input = await oneOnOne.buildOneOnOneInput(String(p._id));
    expect(input!.body).toContain("Nombre: Octavio Ramírez (también: Tavo)");
    expect(input!.body).toContain("Rol: iOS");
    expect(input!.body).toContain("[Equipo de desarrollo] Crash de Panda — blocked");
    expect(input!.body).toContain("Falta acceso a Crashlytics");
    expect(input!.body).toContain("> Yo: Tavo, buenos días, ¿qué tienes hoy?");
    expect(input!.body).not.toContain("Mañana revisamos");
  });

  it("genera y guarda el resultado con su costo", async () => {
    const p = await m.PersonModel.create({ name: "Octavio Ramírez" });
    const result: OneOnOne = {
      summary: "Va bien.",
      wins: ["Cerró los crash"],
      blockers: [],
      workload_signals: null,
      topics: ["Siguiente sprint"],
      questions: ["¿Qué te ayudaría?"],
    };
    const stream = vi.fn(() => ({
      finalMessage: async () => ({
        stop_reason: "end_turn",
        parsed_output: result,
        model: "claude-sonnet-5-5",
        usage: { input_tokens: 2000, output_tokens: 500, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
      }),
    }));
    const fake = { beta: { messages: { stream } } } as unknown as Anthropic;
    const input = await oneOnOne.buildOneOnOneInput(String(p._id));
    const out = await oneOnOne.generateOneOnOne(input!, fake);
    expect(out.result).toEqual(result);
    expect(out.usage.costUsd).toBeCloseTo((2000 * 2 + 500 * 10) / 1e6, 8);
    const params = (stream.mock.calls[0] as unknown as [Record<string, unknown>])[0];
    expect(params).toMatchObject({ model: "claude-sonnet-5-5", fallbacks: "default" });
  });
});

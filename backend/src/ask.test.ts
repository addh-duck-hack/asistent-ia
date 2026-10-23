import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";
import type Anthropic from "@anthropic-ai/sdk";

vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis: vi.fn(), ANALYZE_SESSION_JOB: "analyze-session" }));
// La ruta usa un answerQuestion falso; la prueba del loop usa el real (vi.importActual).
const fakeAnswer = vi.fn();
vi.mock("./llm/ask.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./llm/ask.js")>()),
  answerQuestion: (...args: unknown[]) => fakeAnswer(...args),
}));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let m: typeof import("./models/index.js");
let tools: typeof import("./llm/askTools.js");

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_ask_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  m = await import("./models/index.js");
  tools = await import("./llm/askTools.js");
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
  // dropDatabase también borra los índices de texto que usa la búsqueda.
  await Promise.all([m.TranscriptModel.createIndexes(), m.AnalysisModel.createIndexes()]);
  fakeAnswer.mockReset();
});

const headers = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
const api = (path: string, method = "GET", body?: unknown) =>
  fetch(`${base}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });

const analysis = (executive: string, extra: Record<string, unknown> = {}) => ({
  summary: { executive },
  topics: [],
  decisions: [],
  action_items: [],
  risks: [],
  blockers: [],
  open_questions: [],
  followups_from_previous: [],
  team_signals: { workload: null, morale: null, dependencies: [] },
  ...extra,
});

async function seed() {
  const panda = await m.ProjectModel.create({ name: "Panda" });
  const toks = await m.ProjectModel.create({ name: "TOKS" });
  const octavio = await m.PersonModel.create({ name: "Octavio Ramírez", aliases: ["Tavo"] });
  const mk = async (projectId: mongoose.Types.ObjectId, title: string, date: string, text: string, executive: string, extra = {}) => {
    const s = await m.SessionModel.create({ projectId, type: "meeting", title, date: new Date(date), status: "done" });
    await m.TranscriptModel.create({ sessionId: s._id, text });
    await m.AnalysisModel.create({ sessionId: s._id, result: analysis(executive, extra), summaryText: executive, model: "x", promptVersion: "v" });
    return s;
  };
  const pagos = await mk(panda._id, "Planning pagos", "2026-10-05T15:00:00Z",
    "Yo: ¿Cómo vamos con el pago con tarjeta?\nOtros: Falta la certificación del banco.\nYo: Entonces lanzamos el viernes.",
    "Se decidió lanzar los pagos con tarjeta el viernes.",
    { decisions: [{ decision: "Lanzar pagos el viernes", decided_by: "Adrian", context: "QA ok" }] });
  const daily = await mk(panda._id, "Daily", "2026-10-20T15:00:00Z",
    "Yo: Tavo, ¿qué tienes hoy?\nOtros: Los crash de Panda.", "Daily del equipo.");
  const otro = await mk(toks._id, "Kickoff TOKS", "2026-10-21T15:00:00Z",
    "Otros: Hablemos del pago a proveedores.", "Arranque del proyecto TOKS.");
  await m.ActionItemModel.create({ projectId: panda._id, sessionId: daily._id, task: "Arreglar crash", owner: "Octavio Ramírez", ownerId: octavio._id, status: "blocked",
    history: [{ status: "blocked", note: "Espera acceso a prod", at: new Date("2026-10-21") }] });
  await m.ActionItemModel.create({ projectId: toks._id, task: "Contrato", owner: "Ana", status: "open" });
  return { panda, toks, octavio, pagos, daily, otro };
}

describe("herramientas de Preguntar", () => {
  it("search_sessions encuentra por texto en español (plural/singular) y respeta proyecto y fechas", async () => {
    const { panda, pagos, otro } = await seed();
    const all = await tools.searchSessions({ query: "pagos" });
    expect(all.map((s) => s.session_id)).toEqual(expect.arrayContaining([String(pagos._id), String(otro._id)]));
    expect(all[0]!.session_id).toBe(String(pagos._id)); // aparece en el resumen: pesa más
    expect(all[0]!.summary).toContain("tarjeta");

    const scoped = await tools.searchSessions({ query: "pagos", project_id: String(panda._id) });
    expect(scoped.map((s) => s.session_id)).toEqual([String(pagos._id)]);
    expect(await tools.searchSessions({ query: "pagos", project_id: String(panda._id), from: "2026-10-10" })).toEqual([]);
  });

  it("search_sessions usa regex cuando el índice de texto no encuentra nada", async () => {
    const { daily } = await seed();
    const hits = await tools.searchSessions({ query: "Tavo" });
    expect(hits.map((s) => s.session_id)).toContain(String(daily._id));
  });

  it("list_sessions, get_session, search_transcript y list_action_items", async () => {
    const { panda, octavio, pagos, daily } = await seed();
    const list = await tools.listSessions({ project_id: String(panda._id) });
    expect(list.map((s) => s.title)).toEqual(["Planning pagos", "Daily"]); // cronológico

    const detail = await tools.getSession(String(daily._id));
    expect(detail).toMatchObject({ title: "Daily", project: "Panda", action_items: [{ task: "Arreglar crash", status: "blocked" }] });
    expect(await tools.getSession("nope")).toEqual({ error: "No existe una sesión con ese id." });

    const lines = await tools.searchTranscript(String(pagos._id), "certificación");
    expect(lines).toEqual({
      lines: ["Yo: ¿Cómo vamos con el pago con tarjeta?", "Otros: Falta la certificación del banco.", "Yo: Entonces lanzamos el viernes."],
      truncated: false,
    });

    const items = await tools.listActionItems({ person_id: String(octavio._id) });
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ task: "Arreglar crash", project: "Panda", session: { title: "Daily" }, history: [{ note: "Espera acceso a prod" }] });
  });
});

describe("answerQuestion", () => {
  it("recorre el loop de herramientas, suma el costo y extrae citas", async () => {
    const { panda, pagos } = await seed();
    const { answerQuestion } = await vi.importActual<typeof import("./llm/ask.js")>("./llm/ask.js");
    const usage = { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
    const msgs = [
      { model: "claude-sonnet-5-5", stop_reason: "tool_use", usage, content: [{ type: "tool_use", id: "t1", name: "search_sessions", input: { query: "pagos" } }] },
      { model: "claude-sonnet-5-5", stop_reason: "end_turn", usage, content: [{ type: "text", text: `Se lanzan el viernes [[sesion:${pagos._id}]].` }] },
    ];
    const toolRunner = vi.fn(() => ({ async *[Symbol.asyncIterator]() { yield* msgs; } }));
    const fake = { beta: { messages: { toolRunner } } } as unknown as Anthropic;

    const out = await answerQuestion({ question: "¿Cuándo salen los pagos?", history: [{ role: "user", content: "hola" }, { role: "assistant", content: "¿En qué te ayudo?" }], scope: { projectId: String(panda._id) } }, fake);
    expect(out.answer).toContain("viernes");
    expect(out.citations).toEqual([String(pagos._id)]);
    expect(out.toolCalls).toBe(1);
    expect(out.usage.inputTokens).toBe(2000);
    expect(out.usage.costUsd).toBeCloseTo(2 * (1000 * 2 + 200 * 10) / 1e6, 6);

    const params = (toolRunner.mock.calls[0] as unknown as [Record<string, any>])[0];
    expect(params.max_iterations).toBe(10);
    expect(params.tools.map((t: { name: string }) => t.name)).toEqual(["search_sessions", "list_sessions", "get_session", "search_transcript", "list_action_items"]);
    expect(params.system[1].text).toContain("Octavio Ramírez (id");
    expect(params.system[1].text).toContain("también: Tavo");
    expect(params.system[1].text).toContain("Alcance: la conversación es sobre el proyecto Panda");
    expect(params.messages).toHaveLength(3);
    expect(params.messages[2].content[0]).toMatchObject({ text: "¿Cuándo salen los pagos?", cache_control: { type: "ephemeral" } });
  });
});

describe("/api/conversations", () => {
  it("crea, sigue, lista y borra conversaciones; guarda solo citas que existen", async () => {
    const { pagos } = await seed();
    fakeAnswer.mockResolvedValueOnce({
      answer: `El viernes [[sesion:${pagos._id}]] [[sesion:${"f".repeat(24)}]]`,
      citations: [String(pagos._id), "f".repeat(24)],
      model: "claude-sonnet-5-5", promptVersion: "ask-v1", toolCalls: 2,
      usage: { inputTokens: 3000, outputTokens: 300, costUsd: 0.01 },
    });
    const created = await api("/api/conversations", "POST", { question: "¿Cuándo salen los pagos?" });
    expect(created.status).toBe(201);
    const c = await created.json();
    expect(c.title).toBe("¿Cuándo salen los pagos?");
    expect(c.messages.map((x: { role: string }) => x.role)).toEqual(["user", "assistant"]);
    expect(c.messages[1].citations).toEqual([String(pagos._id)]);
    expect(c.sessions).toMatchObject([{ title: "Planning pagos" }]);

    fakeAnswer.mockResolvedValueOnce({ answer: "Sí.", citations: [], model: "m", promptVersion: "ask-v1", toolCalls: 0, usage: { inputTokens: 1, outputTokens: 1, costUsd: 0.002 } });
    const follow = await (await api(`/api/conversations/${c._id}/messages`, "POST", { question: "¿Seguro?" })).json();
    expect(follow.messages).toHaveLength(4);
    expect(follow.costUsd).toBeCloseTo(0.012);
    expect(fakeAnswer.mock.calls[1]![0].history).toHaveLength(2);

    const list = await (await api("/api/conversations")).json();
    expect(list).toHaveLength(1);
    expect((await api(`/api/conversations/${c._id}`, "DELETE")).status).toBe(200);
    expect((await api(`/api/conversations/${c._id}`)).status).toBe(404);
    expect((await api("/api/conversations", "POST", { question: "" })).status).toBe(400);
  });
});

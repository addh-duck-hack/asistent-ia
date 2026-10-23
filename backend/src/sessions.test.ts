import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";
import type { Analysis } from "@asistent-ia/schema";
import type { AnalyzeInput, AnalyzeOutput } from "./llm/analyze.js";

// La cola real (Agenda) no se usa en estas pruebas.
const enqueueAnalysis = vi.fn(async (_id: string) => {});
vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis, ANALYZE_SESSION_JOB: "analyze-session" }));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let models: typeof import("./models/index.js");
let runAnalyzeSession: typeof import("./jobs/analyzeSession.js").runAnalyzeSession;
let NonRetryable: typeof import("./llm/analyze.js").NonRetryableAnalysisError;

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_sessions_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  models = await import("./models/index.js");
  ({ runAnalyzeSession } = await import("./jobs/analyzeSession.js"));
  ({ NonRetryableAnalysisError: NonRetryable } = await import("./llm/analyze.js"));
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
const post = (path: string, body: unknown) =>
  fetch(`${base}${path}`, { method: "POST", headers, body: JSON.stringify(body) });

function fakeResult(overrides: Partial<Analysis> = {}): Analysis {
  return {
    summary: { executive: "Se acordó lanzar pagos el viernes." },
    topics: [{ title: "Pagos", key_points: ["Endpoint listo"], timestamp: null }],
    decisions: [{ decision: "Lanzar el viernes", decided_by: "Ana", context: "QA ok" }],
    action_items: [
      { task: "Escribir tests de pagos", owner: "Carlos", due_date: "2026-10-24", priority: "high" },
      { task: "Revisar logs", owner: "Alguien", due_date: "el viernes", priority: "low" },
    ],
    risks: [],
    blockers: [],
    open_questions: [],
    followups_from_previous: [],
    team_signals: { workload: null, morale: null, dependencies: [] },
    ...overrides,
  };
}

const fakeAnalyzer = (result = fakeResult()) =>
  vi.fn(
    async (input: AnalyzeInput): Promise<AnalyzeOutput> => ({
      result,
      depth: input.depth,
      model: "claude-sonnet-5-5",
      effort: "medium",
      promptVersion: "analysis-v4",
      usage: { inputTokens: 1000, outputTokens: 500, cacheReadInputTokens: 0, cacheCreationInputTokens: 800, costUsd: 0.009 },
    }),
  );

const VTT = `WEBVTT

00:00:01.000 --> 00:00:04.000
<v Ana López>Carlos, ¿terminaste pagos?</v>

00:00:04.500 --> 00:00:09.000
<v Carlos Ruiz>Sí, mañana escribo los tests.</v>
`;

async function createProjectWithPeople() {
  const carlos = await models.PersonModel.create({ name: "Carlos Ruiz", aliases: ["Charly"] });
  const project = await models.ProjectModel.create({ name: "Portal", context: "Pagos con Stripe", members: [carlos._id] });
  return { project, carlos };
}

describe("POST /api/sessions", () => {
  it("crea la sesión desde un VTT de Teams y encola el análisis", async () => {
    const { project } = await createProjectWithPeople();
    const r = await post("/api/sessions", {
      projectId: String(project._id),
      type: "meeting",
      title: "Daily",
      date: "2026-10-22T15:00:00Z",
      transcript: { format: "vtt", content: VTT },
    });
    expect(r.status).toBe(201);
    const session = await r.json();
    expect(session.status).toBe("pending");
    expect(session.participants).toEqual(["Ana López", "Carlos Ruiz"]);
    expect(enqueueAnalysis).toHaveBeenCalledWith(session._id);

    const transcript = await models.TranscriptModel.findOne({ sessionId: session._id }).lean();
    expect(transcript!.segments).toHaveLength(2);
    expect(transcript!.text).toBe("Ana López: Carlos, ¿terminaste pagos?\nCarlos Ruiz: Sí, mañana escribo los tests.");
  });

  it("guarda el nivel de análisis elegido", async () => {
    const { project } = await createProjectWithPeople();
    const r = await post("/api/sessions", {
      projectId: String(project._id),
      type: "pasted",
      title: "Cliente",
      date: "2026-10-22",
      depth: "deep",
      transcript: { content: "Reunión con el cliente." },
    });
    expect((await r.json()).depth).toBe("deep");
  });

  it("expone los niveles con su modelo", async () => {
    const profiles = await fetch(`${base}/api/analysis-profiles`, { headers }).then((r) => r.json());
    expect(profiles.map((p: { depth: string; model: string }) => `${p.depth}:${p.model}`)).toEqual([
      "quick:claude-sonnet-5-5",
      "standard:claude-sonnet-5-5",
      "deep:claude-opus-5-5",
    ]);
  });

  it("acepta texto plano", async () => {
    const { project } = await createProjectWithPeople();
    const r = await post("/api/sessions", {
      projectId: String(project._id),
      type: "pasted",
      title: "Notas",
      date: "2026-10-22",
      transcript: { content: "Se habló de pagos." },
    });
    expect(r.status).toBe(201);
  });

  it("valida el cuerpo y el proyecto", async () => {
    const { project } = await createProjectWithPeople();
    const base = { projectId: String(project._id), type: "pasted", title: "x", date: "2026-10-22" };
    expect((await post("/api/sessions", { ...base, transcript: { content: "  " } })).status).toBe(400);
    expect((await post("/api/sessions", { ...base, type: "zoom", transcript: { content: "a" } })).status).toBe(400);
    expect((await post("/api/sessions", { ...base, transcript: { format: "vtt", content: "WEBVTT" } })).status).toBe(400);
    expect(
      (await post("/api/sessions", { ...base, projectId: "0".repeat(24), transcript: { content: "a" } })).status,
    ).toBe(404);
    expect(enqueueAnalysis).not.toHaveBeenCalled();
  });
});

describe("runAnalyzeSession", () => {
  async function createSession() {
    const { project, carlos } = await createProjectWithPeople();
    const r = await post("/api/sessions", {
      projectId: String(project._id),
      type: "meeting",
      title: "Daily",
      date: "2026-10-22T15:00:00Z",
      transcript: { format: "vtt", content: VTT },
    });
    const session = await r.json();
    return { project, carlos, sessionId: session._id as string };
  }

  it("guarda el análisis, crea los action items y marca la sesión como done", async () => {
    const { carlos, sessionId } = await createSession();
    const analyze = fakeAnalyzer();
    await runAnalyzeSession(sessionId, analyze);

    const input = analyze.mock.calls[0]![0];
    expect(input.depth).toBe("standard");
    expect(input.project).toMatchObject({ name: "Portal", context: "Pagos con Stripe", members: ["Carlos Ruiz"] });
    expect(input.transcript.segments[0]).toMatchObject({ speaker: "Ana López" });

    const detail = await fetch(`${base}/api/sessions/${sessionId}`, { headers }).then((r) => r.json());
    expect(detail.session.status).toBe("done");
    expect(detail.analysis.summaryText).toBe("Se acordó lanzar pagos el viernes.");
    expect(detail.analysis.usage.cacheCreationInputTokens).toBe(800);
    expect(detail.analysis).toMatchObject({ depth: "standard", model: "claude-sonnet-5-5", effort: "medium" });
    expect(detail.analysis.usage.costUsd).toBe(0.009);
    expect(detail.actionItems).toHaveLength(2);
    const [tests, logs] = detail.actionItems;
    expect(tests.ownerId).toBe(String(carlos._id)); // "Carlos" → Carlos Ruiz por primer nombre
    expect(tests.dueDate).toBe("2026-10-24T00:00:00.000Z");
    expect(logs.ownerId).toBeUndefined();
    expect(logs.dueDate).toBeUndefined(); // "el viernes" no es ISO

    const list = await fetch(`${base}/api/projects/${detail.session.projectId}/sessions`, { headers }).then((r) => r.json());
    expect(list[0].summary).toBe("Se acordó lanzar pagos el viernes.");
    expect(list[0].costUsd).toBe(0.009);
  });

  it("pasa los pendientes abiertos de otras sesiones como contexto", async () => {
    const first = await createSession();
    await runAnalyzeSession(first.sessionId, fakeAnalyzer());
    const r = await post("/api/sessions", {
      projectId: String(first.project._id),
      type: "pasted",
      title: "Seguimiento",
      date: "2026-10-23",
      transcript: { content: "Carlos ya terminó los tests." },
    });
    const second = await r.json();
    const analyze = fakeAnalyzer(fakeResult({ action_items: [] }));
    await runAnalyzeSession(second._id, analyze);
    const openItems = analyze.mock.calls[0]![0].openItems;
    expect(openItems.map((i) => i.task).sort()).toEqual(["Escribir tests de pagos", "Revisar logs"]);
  });

  it("al re-analizar reemplaza los pendientes que la sesión creó", async () => {
    const { sessionId } = await createSession();
    await runAnalyzeSession(sessionId, fakeAnalyzer());
    await runAnalyzeSession(sessionId, fakeAnalyzer(fakeResult({ action_items: [fakeResult().action_items[0]!] })));
    expect(await models.ActionItemModel.countDocuments({ sessionId })).toBe(1);
  });

  it("marca la sesión como failed y propaga el error", async () => {
    const { sessionId } = await createSession();
    const analyze = vi.fn(async () => {
      throw new NonRetryable("Claude rechazó el análisis (cyber)");
    });
    await expect(runAnalyzeSession(sessionId, analyze)).rejects.toBeInstanceOf(NonRetryable);
    const session = await models.SessionModel.findById(sessionId).lean();
    expect(session).toMatchObject({ status: "failed", error: "Claude rechazó el análisis (cyber)" });

    const r = await post(`/api/sessions/${sessionId}/reanalyze`, { depth: "deep" });
    expect(r.status).toBe(202);
    expect(await r.json()).toMatchObject({ status: "pending", depth: "deep" });
    expect((await post(`/api/sessions/${sessionId}/reanalyze`, { depth: "turbo" })).status).toBe(400);
    expect(enqueueAnalysis).toHaveBeenCalledWith(sessionId);
  });
});

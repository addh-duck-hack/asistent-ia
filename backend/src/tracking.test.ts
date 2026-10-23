import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";
import type Anthropic from "@anthropic-ai/sdk";
import type { Analysis, Digest } from "@asistent-ia/schema";
import type { AnalyzeInput, AnalyzeOutput } from "./llm/analyze.js";

vi.mock("./jobs/queue.js", () => ({ enqueueAnalysis: vi.fn(), ANALYZE_SESSION_JOB: "analyze-session" }));

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;
let m: typeof import("./models/index.js");
let runAnalyzeSession: typeof import("./jobs/analyzeSession.js").runAnalyzeSession;
let digestJobs: typeof import("./jobs/digest.js");
let buildDigestInput: typeof import("./llm/digest.js").buildDigestInput;

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_tracking_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  m = await import("./models/index.js");
  ({ runAnalyzeSession } = await import("./jobs/analyzeSession.js"));
  digestJobs = await import("./jobs/digest.js");
  ({ buildDigestInput } = await import("./llm/digest.js"));
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

function result(overrides: Partial<Analysis> = {}): Analysis {
  return {
    summary: { executive: "Resumen." },
    topics: [],
    decisions: [],
    action_items: [],
    risks: [],
    blockers: [],
    open_questions: [],
    followups_from_previous: [],
    team_signals: { workload: null, morale: null, dependencies: [] },
    ...overrides,
  };
}

const analyzer = (r: Analysis) =>
  vi.fn(
    async (input: AnalyzeInput): Promise<AnalyzeOutput> => ({
      result: r,
      depth: input.depth,
      model: "claude-sonnet-5-5",
      effort: "medium",
      promptVersion: "analysis-v3",
      usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, costUsd: 0 },
    }),
  );

async function session(projectId: unknown, title: string, date: string) {
  const s = await m.SessionModel.create({ projectId, type: "pasted", title, date: new Date(date) });
  await m.TranscriptModel.create({ sessionId: s._id, text: "texto" });
  return s;
}

describe("seguimiento entre sesiones", () => {
  it("cierra un pendiente de la daily del lunes cuando se habla en la del miércoles", async () => {
    const project = await m.ProjectModel.create({ name: "Portal" });
    const monday = await session(project._id, "Daily lunes", "2026-10-19T15:00:00Z");
    await runAnalyzeSession(
      String(monday._id),
      analyzer(result({ action_items: [{ task: "Tests de pagos", owner: "Carlos", due_date: null, priority: "high" }] })),
    );
    const item = await m.ActionItemModel.findOne({ task: "Tests de pagos" }).lean();
    expect(item!.status).toBe("open");

    const wednesday = await session(project._id, "Daily miércoles", "2026-10-21T15:00:00Z");
    const analyze = analyzer(
      result({
        followups_from_previous: [
          { action_item_id: String(item!._id), status: "done", note: "Carlos terminó los tests" },
          { action_item_id: "0".repeat(24), status: "done", note: "id inventado" },
        ],
      }),
    );
    await runAnalyzeSession(String(wednesday._id), analyze);
    expect(analyze.mock.calls[0]![0].openItems.map((i) => i.id)).toEqual([String(item!._id)]);

    let updated = await m.ActionItemModel.findById(item!._id).lean();
    expect(updated!.status).toBe("done");
    expect(updated!.history).toHaveLength(1);
    expect(updated!.history[0]).toMatchObject({ status: "done", note: "Carlos terminó los tests" });

    // Re-analizar no duplica la nota.
    await runAnalyzeSession(String(wednesday._id), analyze);
    updated = await m.ActionItemModel.findById(item!._id).lean();
    expect(updated!.history).toHaveLength(1);
  });

  it("not_discussed no cambia nada", async () => {
    const project = await m.ProjectModel.create({ name: "Portal" });
    const s1 = await session(project._id, "S1", "2026-10-19");
    await runAnalyzeSession(
      String(s1._id),
      analyzer(result({ action_items: [{ task: "Deploy", owner: null, due_date: null, priority: "low" }] })),
    );
    const item = await m.ActionItemModel.findOne().lean();
    const s2 = await session(project._id, "S2", "2026-10-20");
    await runAnalyzeSession(
      String(s2._id),
      analyzer(result({ followups_from_previous: [{ action_item_id: String(item!._id), status: "not_discussed", note: "" }] })),
    );
    expect((await m.ActionItemModel.findById(item!._id).lean())!.history).toHaveLength(0);
  });
});

describe("API de pendientes", () => {
  it("lista abiertos ordenados por fecha y permite editarlos con historial", async () => {
    const p1 = await m.ProjectModel.create({ name: "Portal" });
    const p2 = await m.ProjectModel.create({ name: "App" });
    const s = await session(p1._id, "Planning", "2026-10-20");
    const base_ = { sessionId: s._id, priority: "medium" };
    await m.ActionItemModel.create([
      { ...base_, projectId: p1._id, task: "Sin fecha" },
      { ...base_, projectId: p1._id, task: "Vence tarde", dueDate: new Date("2026-11-10") },
      { ...base_, projectId: p1._id, task: "Vence pronto", dueDate: new Date("2026-10-25") },
      { ...base_, projectId: p1._id, task: "Hecho", status: "done" },
      { ...base_, projectId: p2._id, task: "Otro proyecto" },
    ]);

    const list = await fetch(`${base}/api/action-items?projectId=${p1._id}`, { headers }).then((r) => r.json());
    expect(list.map((i: { task: string }) => i.task)).toEqual(["Vence pronto", "Vence tarde", "Sin fecha"]);
    expect(list[0].sessionId.title).toBe("Planning");
    expect(list[0].projectId.name).toBe("Portal");

    const done = await fetch(`${base}/api/action-items?status=done`, { headers }).then((r) => r.json());
    expect(done.map((i: { task: string }) => i.task)).toEqual(["Hecho"]);
    expect((await fetch(`${base}/api/action-items?status=zzz`, { headers })).status).toBe(400);

    const id = list[0]._id;
    const patched = await fetch(`${base}/api/action-items/${id}`, {
      method: "PATCH",
      headers,
      body: JSON.stringify({ status: "done", owner: "Ana", note: "Cerrado en la revisión" }),
    }).then((r) => r.json());
    expect(patched).toMatchObject({ status: "done", owner: "Ana" });
    expect(patched.history.at(-1)).toMatchObject({ status: "done", note: "Cerrado en la revisión" });

    const cleared = await fetch(`${base}/api/action-items/${id}`, {
      method: "PATCH",
      headers,
      body: JSON.stringify({ dueDate: null, priority: "high" }),
    }).then((r) => r.json());
    expect(cleared.dueDate).toBeUndefined();
    expect(cleared.history).toHaveLength(1); // sin cambio de estado ni nota: no agrega historial
  });
});

const digestResult: Digest = {
  summary: "Semana con avance en pagos.",
  highlights: ["Endpoint de pagos listo"],
  decisions: [{ decision: "Lanzar el viernes", session: "Planning" }],
  completed: ["Tests de pagos"],
  attention: [{ task: "Acceso a Stripe", owner: null, reason: "Bloqueado" }],
  risks: [],
  next_week_focus: ["Lanzamiento"],
};

describe("resumen semanal", () => {
  async function seedWeek() {
    const project = await m.ProjectModel.create({ name: "Portal", context: "Stripe" });
    const s = await session(project._id, "Planning", "2026-10-20T15:00:00Z");
    await runAnalyzeSession(
      String(s._id),
      analyzer(
        result({
          summary: { executive: "Se planeó el lanzamiento." },
          decisions: [{ decision: "Lanzar el viernes", decided_by: "Ana", context: "" }],
          action_items: [{ task: "Pedir acceso a Stripe", owner: null, due_date: "2026-10-21", priority: "high" }],
        }),
      ),
    );
    // Sesión fuera del periodo: no debe aparecer.
    await session(project._id, "Vieja", "2026-09-01");
    return project;
  }

  it("arma la semana con análisis y pendientes (vencidos marcados)", async () => {
    const project = await seedWeek();
    const input = await buildDigestInput(String(project._id), new Date("2026-10-18"), new Date("2026-10-25"));
    expect(input!.sessionCount).toBe(1);
    expect(input!.body).toContain("Se planeó el lanzamiento.");
    expect(input!.body).toContain("Lanzar el viernes");
    expect(input!.body).toContain("Pedir acceso a Stripe — sin responsable — open, vence 2026-10-21 (VENCIDO)");
    expect(input!.body).not.toContain("Vieja");
    expect(await buildDigestInput(String(project._id), new Date("2026-01-01"), new Date("2026-01-08"))).toBeNull();
  });

  it("envía un lote los lunes y guarda los resúmenes cuando termina", async () => {
    const project = await seedWeek();
    const create = vi.fn(async (_body: unknown) => ({ id: "msgbatch_1" }));
    let status = "in_progress";
    const fake = {
      messages: {
        batches: {
          create,
          retrieve: vi.fn(async () => ({ processing_status: status })),
          results: vi.fn(async () =>
            (async function* () {
              yield {
                custom_id: `digest-${project._id}`,
                result: {
                  type: "succeeded",
                  message: {
                    model: "claude-sonnet-5-5",
                    content: [{ type: "thinking", thinking: "" }, { type: "text", text: JSON.stringify(digestResult) }],
                    usage: { input_tokens: 3000, output_tokens: 800 },
                  },
                },
              };
            })(),
          ),
        },
      },
    } as unknown as Anthropic;

    await digestJobs.runWeeklyDigest(new Date("2026-10-26T14:00:00Z"), fake);
    const body = create.mock.calls[0]![0] as { requests: { custom_id: string; params: Record<string, unknown> }[] };
    expect(body.requests).toHaveLength(1);
    expect(body.requests[0]!.custom_id).toBe(`digest-${project._id}`);
    expect(body.requests[0]!.params).not.toHaveProperty("fallbacks"); // la Batch API no lo admite
    expect(await m.DigestBatchModel.countDocuments({ status: "pending" })).toBe(1);

    await digestJobs.pollDigestBatches(fake); // aún en proceso
    expect(await m.DigestModel.countDocuments()).toBe(0);

    status = "ended";
    await digestJobs.pollDigestBatches(fake);
    const digests = await fetch(`${base}/api/projects/${project._id}/digests`, { headers }).then((r) => r.json());
    expect(digests).toHaveLength(1);
    expect(digests[0]).toMatchObject({ source: "scheduled", sessionCount: 1, result: digestResult });
    // Precio de lista de Sonnet 5.5 a mitad de precio por la Batch API.
    expect(digests[0].usage.costUsd).toBeCloseTo((3000 * 2 + 800 * 10) / 1e6 / 2, 8);
    expect(await m.DigestBatchModel.countDocuments({ status: "done" })).toBe(1);
  });

  it("sin sesiones en la semana no envía lote", async () => {
    const create = vi.fn();
    const fake = { messages: { batches: { create } } } as unknown as Anthropic;
    await digestJobs.runWeeklyDigest(new Date("2026-10-26"), fake);
    expect(create).not.toHaveBeenCalled();
  });

  it("Generar ahora responde 422 si no hay sesiones", async () => {
    const project = await m.ProjectModel.create({ name: "Vacío" });
    const r = await fetch(`${base}/api/projects/${project._id}/digests`, { method: "POST", headers, body: "{}" });
    expect(r.status).toBe(422);
  });
});

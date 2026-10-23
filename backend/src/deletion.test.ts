import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
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
  process.env.MONGO_URL = mongo.getUri("asistent_ia_deletion_test");
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

const del = (path: string) => fetch(`${base}${path}`, { method: "DELETE", headers: { authorization: `Bearer ${TOKEN}` } });

/** Dos proyectos; en "TOKS" una persona, dos sesiones, pendientes y un resumen. */
async function seed() {
  const ana = await m.PersonModel.create({ name: "Ana López" });
  const toks = await m.ProjectModel.create({ name: "TOKS", members: [ana._id] });
  const other = await m.ProjectModel.create({ name: "Otro", members: [ana._id] });
  const s1 = await m.SessionModel.create({ projectId: toks._id, type: "pasted", title: "S1", date: new Date() });
  const s2 = await m.SessionModel.create({ projectId: toks._id, type: "pasted", title: "S2", date: new Date() });
  const sOther = await m.SessionModel.create({ projectId: other._id, type: "pasted", title: "Otra", date: new Date() });
  for (const s of [s1, s2, sOther]) {
    await m.TranscriptModel.create({ sessionId: s._id, text: "t" });
    await m.AnalysisModel.create({ sessionId: s._id, result: {}, model: "x", promptVersion: "v" });
  }
  const fromS1 = await m.ActionItemModel.create({ projectId: toks._id, sessionId: s1._id, task: "De S1", ownerId: ana._id, owner: "Ana López" });
  // Pendiente nacido en S2 cuyo cierre se detectó en S1 (historial que apunta a S1).
  const fromS2 = await m.ActionItemModel.create({
    projectId: toks._id,
    sessionId: s2._id,
    task: "De S2",
    history: [{ sessionId: s1._id, status: "done", note: "Cerrado en S1", at: new Date() }],
    status: "done",
  });
  const manual = await m.ActionItemModel.create({ projectId: toks._id, task: "Manual", source: "manual" });
  const otherItem = await m.ActionItemModel.create({ projectId: other._id, sessionId: sOther._id, task: "De otro proyecto", ownerId: ana._id });
  const digest = await m.DigestModel.create({
    projectId: toks._id,
    periodStart: new Date(),
    periodEnd: new Date(),
    sessionCount: 2,
    result: {},
    source: "manual",
    model: "x",
    promptVersion: "v",
  });
  const prep = await m.OneOnOneModel.create({
    personId: ana._id,
    periodStart: new Date(),
    periodEnd: new Date(),
    result: {},
    model: "x",
    promptVersion: "v",
  });
  return { ana, toks, other, s1, s2, sOther, fromS1, fromS2, manual, otherItem, digest, prep };
}

describe("eliminar", () => {
  it("una sesión borra su transcripción, análisis y pendientes que nacieron en ella; conserva el historial ajeno", async () => {
    const d = await seed();
    const r = await del(`/api/sessions/${d.s1._id}`);
    expect(await r.json()).toEqual({ sessions: 1, actionItems: 1 });
    expect(await m.TranscriptModel.countDocuments({ sessionId: d.s1._id })).toBe(0);
    expect(await m.AnalysisModel.countDocuments({ sessionId: d.s1._id })).toBe(0);
    expect(await m.ActionItemModel.exists({ _id: d.fromS1._id })).toBeNull();
    const kept = await m.ActionItemModel.findById(d.fromS2._id).lean();
    expect(kept!.status).toBe("done");
    expect(kept!.history).toHaveLength(1);
    expect((await del(`/api/sessions/${d.s1._id}`)).status).toBe(404);
  });

  it("un proyecto borra sesiones, pendientes (también manuales) y resúmenes; no toca otros proyectos ni personas", async () => {
    const d = await seed();
    const r = await del(`/api/projects/${d.toks._id}`);
    expect(await r.json()).toEqual({ project: 1, sessions: 2, actionItems: 3, digests: 1 });
    expect(await m.SessionModel.countDocuments({ projectId: d.toks._id })).toBe(0);
    expect(await m.TranscriptModel.countDocuments()).toBe(1);
    expect(await m.ActionItemModel.exists({ _id: d.otherItem._id })).not.toBeNull();
    expect(await m.PersonModel.exists({ _id: d.ana._id })).not.toBeNull();
    expect((await del(`/api/projects/${d.toks._id}`)).status).toBe(404);
  });

  it("una persona borra sus 1:1 y su pertenencia; sus pendientes quedan con nombre pero sin ligar", async () => {
    const d = await seed();
    const r = await del(`/api/people/${d.ana._id}`);
    expect(await r.json()).toEqual({ person: 1, unlinkedItems: 2, oneOnOnes: 1 });
    const item = await m.ActionItemModel.findById(d.fromS1._id).lean();
    expect(item!.ownerId).toBeUndefined();
    expect(item!.owner).toBe("Ana López");
    expect(await m.ProjectModel.countDocuments({ members: d.ana._id })).toBe(0);
  });

  it("pendiente, resumen y 1:1 se borran de uno en uno", async () => {
    const d = await seed();
    expect((await del(`/api/action-items/${d.manual._id}`)).status).toBe(200);
    expect(await m.ActionItemModel.exists({ _id: d.manual._id })).toBeNull();
    // El resumen solo se borra desde su proyecto.
    expect((await del(`/api/projects/${d.other._id}/digests/${d.digest._id}`)).status).toBe(404);
    expect((await del(`/api/projects/${d.toks._id}/digests/${d.digest._id}`)).status).toBe(200);
    expect((await del(`/api/people/${d.ana._id}/one-on-ones/${d.prep._id}`)).status).toBe(200);
    expect(await m.OneOnOneModel.countDocuments()).toBe(0);
  });
});

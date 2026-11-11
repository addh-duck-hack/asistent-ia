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
  process.env.MONGO_URL = mongo.getUri("asistent_ia_profile_test");
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

it("calcula las vacaciones de la LFT por años cumplidos", async () => {
  const { lftVacationDays, vacationSummary } = await import("./utils/vacations.js");
  expect([0, 1, 2, 3, 4, 5, 6, 10, 11, 15, 16].map(lftVacationDays)).toEqual([0, 12, 14, 16, 18, 20, 22, 22, 24, 24, 26]);

  const day = (s: string) => new Date(`${s}T00:00:00Z`);
  const summary = vacationSummary(
    day("2023-03-15"),
    [
      { startDate: day("2026-04-06"), days: 5 }, // periodo vigente
      { startDate: day("2025-12-22"), days: 6 }, // periodo anterior: no cuenta
    ],
    null,
    day("2026-11-11"),
  );
  expect(summary).toMatchObject({ yearsOfService: 3, total: 16, taken: 5, remaining: 11, nextTotal: 18, source: "law" });
  expect(summary.periodStart).toEqual(day("2026-03-15"));
  // Un día antes del aniversario sigue en el año anterior.
  expect(vacationSummary(day("2023-03-15"), [], null, day("2026-03-14")).total).toBe(14);
  // Primer año: aún no gana días por ley; el ajuste manual manda.
  expect(vacationSummary(day("2026-06-01"), [], null, day("2026-11-11"))).toMatchObject({ total: 0, nextTotal: 12 });
  expect(vacationSummary(day("2026-06-01"), [], 15, day("2026-11-11"))).toMatchObject({ total: 15, source: "override" });
});

it("guarda el perfil y lleva sueldo, vacaciones, horas extra y ánimo", async () => {
  const person = await m.PersonModel.create({ name: "Octavio Ramírez" });
  const url = `/api/people/${person._id}`;

  let res = await api(`${url}/profile`, "PATCH", {
    birthday: "1994-02-20", startDate: "2023-03-15", level: "Senior", contractType: "Nómina",
    skills: ["Swift", "Swift", "Kotlin"], notes: "Quiere liderar.", nextSalaryReview: "2027-01-15",
  });
  expect(res.status).toBe(200);
  let profile = await res.json();
  expect(profile).toMatchObject({ level: "Senior", skills: ["Swift", "Kotlin"], notes: "Quiere liderar.", vacationDaysOverride: null });
  expect(profile.birthday).toBe("1994-02-20T00:00:00.000Z");
  expect(profile.vacation.source).toBe("law");

  // Sueldo: el vigente es el último que ya entró en vigor.
  await api(`${url}/salary`, "POST", { amount: 40_000, effectiveDate: "2023-03-15" });
  await api(`${url}/salary`, "POST", { amount: 48_000, effectiveDate: "2025-03-15", note: "Aumento anual" });
  res = await api(`${url}/salary`, "POST", { amount: 60_000, effectiveDate: "2099-01-01", note: "Programado" });
  expect(res.status).toBe(201);
  profile = await res.json();
  expect(profile.salary.current).toMatchObject({ amount: 48_000, currency: "MXN", period: "monthly" });
  expect(profile.salary.history.map((s: { amount: number }) => s.amount)).toEqual([60_000, 48_000, 40_000]);
  expect(profile.salary.daysSinceChange).toBeGreaterThan(0);

  // Vacaciones y ajuste manual de días.
  const today = new Date().toISOString().slice(0, 10);
  profile = await (await api(`${url}/vacations`, "POST", { startDate: today, endDate: today, days: 1 })).json();
  expect(profile.vacation.taken).toBe(1);
  expect(profile.vacation.remaining).toBe(profile.vacation.total - 1);
  profile = await (await api(`${url}/profile`, "PATCH", { vacationDaysOverride: 20 })).json();
  expect(profile.vacation).toMatchObject({ total: 20, remaining: 19, source: "override" });
  profile = await (await api(`${url}/profile`, "PATCH", { vacationDaysOverride: null })).json();
  expect(profile.vacation.source).toBe("law");
  expect((await api(`${url}/vacations`, "POST", { startDate: "2026-05-10", endDate: "2026-05-01", days: 3 })).status).toBe(400);

  // Horas extra: pendientes hasta que se pagan o compensan.
  await api(`${url}/overtime`, "POST", { date: today, hours: 3, reason: "Release" });
  profile = await (await api(`${url}/overtime`, "POST", { date: today, hours: 2.5 })).json();
  expect(profile.overtime).toMatchObject({ pendingHours: 5.5, monthHours: 5.5, yearHours: 5.5 });
  const entry = profile.overtime.entries[0]._id;
  profile = await (await api(`${url}/overtime/${entry}`, "PATCH", { status: "paid" })).json();
  expect(profile.overtime.pendingHours).toBe(profile.overtime.entries[1].hours);
  profile = await (await api(`${url}/overtime/${entry}`, "DELETE")).json();
  expect(profile.overtime.entries).toHaveLength(1);

  // Ánimo manual.
  profile = await (await api(`${url}/moods`, "POST", { level: 4, note: "Contento con el release" })).json();
  expect(profile.moods).toHaveLength(1);
  expect((await api(`${url}/moods`, "POST", { level: 6 })).status).toBe(400);

  expect((await api(`${url}/salary/${"a".repeat(24)}`, "DELETE")).status).toBe(404);
  expect((await api(`/api/people/${"a".repeat(24)}/profile`)).status).toBe(404);
});

it("los datos de RH no salen en el listado ni en las consultas normales", async () => {
  const person = await m.PersonModel.create({ name: "Ana López", startDate: new Date("2024-01-08T00:00:00Z") });
  await api(`/api/people/${person._id}/salary`, "POST", { amount: 55_000, effectiveDate: "2024-01-08" });
  await api(`/api/people/${person._id}/profile`, "PATCH", { notes: "Privado" });
  await api(`/api/people/${person._id}/moods`, "POST", { level: 2 });

  const list = await (await api("/api/people")).json();
  expect(list[0].startDate).toBe("2024-01-08T00:00:00.000Z");
  expect(JSON.stringify(list)).not.toMatch(/55000|salaryHistory|Privado|moods|overtime|vacations/);
  // Lo que usan el análisis, Preguntar y el 1:1 para armar el contexto de Claude.
  const plain = await m.PersonModel.findById(person._id).lean();
  expect(JSON.stringify(plain)).not.toMatch(/55000|salaryHistory|Privado|moods/);
});

it("las sugerencias de ánimo de Claude se confirman o se descartan", async () => {
  const { applyMoodSignals } = await import("./jobs/analyzeSession.js");
  const { buildOwnerResolver } = await import("./utils/people.js");
  const { deleteSessions } = await import("./utils/deletion.js");
  const project = await m.ProjectModel.create({ name: "Panda" });
  const [tavo, ana] = await m.PersonModel.create([{ name: "Octavio Ramírez", aliases: ["Tavo"] }, { name: "Ana López" }]);
  const session = await m.SessionModel.create({ projectId: project._id, type: "meeting", title: "Daily", date: new Date("2026-11-10T15:00:00Z") });
  const signals = [
    { person: "Tavo", mood: "low" as const, evidence: "Dijo que lleva tres noches desvelándose." },
    { person: "Ana López", mood: "very_good" as const, evidence: "Celebró que QA aprobó." },
    { person: "Voz 2", mood: "low" as const, evidence: "Sin identificar." },
  ];
  await applyMoodSignals(session, signals, await buildOwnerResolver());
  await applyMoodSignals(session, signals, await buildOwnerResolver()); // re-análisis: no duplica

  let profile = await (await api(`/api/people/${tavo._id}/profile`)).json();
  expect(profile.moodSuggestions).toHaveLength(1);
  expect(profile.moodSuggestions[0]).toMatchObject({ level: 2, sessionTitle: "Daily" });

  // Confirmar corrigiendo el nivel: pasa al historial con la fecha y la sesión.
  const res = await api(`/api/people/${tavo._id}/moods`, "POST", { level: 3, suggestionId: profile.moodSuggestions[0]._id });
  expect(res.status).toBe(201);
  profile = await res.json();
  expect(profile.moodSuggestions).toEqual([]);
  expect(profile.moods[0]).toMatchObject({ level: 3, note: "Dijo que lleva tres noches desvelándose.", sessionId: String(session._id) });

  // Ya confirmado: al re-analizar no se vuelve a sugerir.
  await applyMoodSignals(session, signals, await buildOwnerResolver());
  expect((await (await api(`/api/people/${tavo._id}/profile`)).json()).moodSuggestions).toEqual([]);

  // Descartar, y borrar la sesión se lleva sus sugerencias.
  const anaProfile = await (await api(`/api/people/${ana._id}/profile`)).json();
  expect(anaProfile.moodSuggestions[0].level).toBe(5);
  await deleteSessions([session._id]);
  expect((await (await api(`/api/people/${ana._id}/profile`)).json()).moodSuggestions).toEqual([]);
  await applyMoodSignals(session, signals.slice(1, 2), await buildOwnerResolver());
  const again = await (await api(`/api/people/${ana._id}/profile`)).json();
  const dismissed = await api(`/api/people/${ana._id}/mood-suggestions/${again.moodSuggestions[0]._id}`, "DELETE");
  expect((await dismissed.json()).moodSuggestions).toEqual([]);
});

it("el prompt pide mood_signals como sugerencia prudente", async () => {
  const { ANALYSIS_SYSTEM_PROMPT } = await import("./llm/prompts/analysis.js");
  expect(ANALYSIS_SYSTEM_PROMPT).toContain("mood_signals");
});

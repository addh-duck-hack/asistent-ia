import { Router, type Response } from "express";
import { z } from "zod";
import { OneOnOneModel, PersonModel, PROFILE_FIELDS, SessionModel } from "../models/index.js";
import { vacationSummary } from "../utils/vacations.js";

// Perfil de RH de cada persona: fechas, sueldo e histórico, vacaciones, horas
// extra y estado de ánimo. Nada de esto se le envía a Claude (ver models/Person.ts).
export const profileRouter = Router();

const ObjectId = z.string().regex(/^[a-f\d]{24}$/i, "id inválido");
// Fechas de calendario: "2026-11-11" → medianoche UTC.
const Day = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "fecha inválida (YYYY-MM-DD)")
  .transform((s) => new Date(`${s}T00:00:00Z`))
  .refine((d) => !Number.isNaN(d.getTime()), "fecha inválida");
const Note = z.string().trim().max(2000).optional();

const DAY = 86_400_000;
const startOfDay = (d = new Date()) => new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));

async function loadProfile(id: string) {
  return PersonModel.findById(ObjectId.parse(id)).select(PROFILE_FIELDS);
}
type ProfileDoc = NonNullable<Awaited<ReturnType<typeof loadProfile>>>;

async function buildProfile(person: ProfileDoc, now = new Date()) {
  const p = person.toObject();
  const today = startOfDay(now);
  const byDateDesc = <T extends { date?: Date; effectiveDate?: Date; startDate?: Date }>(list: T[]) =>
    [...list].sort((a, b) => +(b.date ?? b.effectiveDate ?? b.startDate ?? 0) - +(a.date ?? a.effectiveDate ?? a.startDate ?? 0));

  const salaryHistory = byDateDesc(p.salaryHistory ?? []);
  // El vigente es el más reciente que ya entró en vigor (puede haber un aumento programado).
  const current = salaryHistory.find((s) => s.effectiveDate <= today) ?? null;

  const overtime = byDateDesc(p.overtime ?? []);
  const hours = (from: Date) => overtime.filter((o) => o.date >= from).reduce((sum, o) => sum + o.hours, 0);

  const suggestions = byDateDesc(p.moodSuggestions ?? []);
  const [sessions, lastOneOnOne] = await Promise.all([
    SessionModel.find({ _id: { $in: suggestions.map((s) => s.sessionId) } }).select({ title: 1, projectId: 1 }).lean(),
    OneOnOneModel.findOne({ personId: person._id }).sort({ createdAt: -1 }).select({ createdAt: 1 }).lean(),
  ]);
  const sessionById = new Map(sessions.map((s) => [String(s._id), s]));

  return {
    _id: p._id,
    name: p.name,
    birthday: p.birthday ?? null,
    startDate: p.startDate ?? null,
    level: p.level ?? "",
    contractType: p.contractType ?? "",
    skills: p.skills ?? [],
    notes: p.notes ?? "",
    nextSalaryReview: p.nextSalaryReview ?? null,
    vacationDaysOverride: p.vacationDaysOverride ?? null,
    salary: {
      current,
      history: salaryHistory,
      daysSinceChange: current ? Math.floor((+today - +current.effectiveDate) / DAY) : null,
    },
    vacation: p.startDate ? vacationSummary(p.startDate, p.vacations ?? [], p.vacationDaysOverride, today) : null,
    vacations: byDateDesc(p.vacations ?? []),
    overtime: {
      entries: overtime,
      pendingHours: overtime.filter((o) => o.status === "pending").reduce((sum, o) => sum + o.hours, 0),
      monthHours: hours(new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1))),
      yearHours: hours(new Date(Date.UTC(today.getUTCFullYear(), 0, 1))),
    },
    moods: byDateDesc(p.moods ?? []),
    moodSuggestions: suggestions.map((s) => ({
      ...s,
      sessionTitle: sessionById.get(String(s.sessionId))?.title ?? null,
      projectId: sessionById.get(String(s.sessionId))?.projectId ?? null,
    })),
    lastOneOnOneAt: lastOneOnOne?.createdAt ?? null,
  };
}

/** Carga el perfil, aplica el cambio y responde con el perfil completo. */
async function mutate(id: string, res: Response, change: (person: ProfileDoc) => boolean | void, status = 200) {
  const person = await loadProfile(id);
  if (!person || change(person) === false) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  await person.save();
  res.status(status).json(await buildProfile(person));
}

profileRouter.get("/:id/profile", async (req, res) => {
  const person = await loadProfile(req.params.id);
  if (!person) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(await buildProfile(person));
});

// null borra el dato; un campo ausente no se toca.
const ProfileBody = z
  .object({
    birthday: Day.nullable(),
    startDate: Day.nullable(),
    level: z.string().trim().max(60),
    contractType: z.string().trim().max(60),
    skills: z.array(z.string().trim().min(1).max(40)).max(40),
    notes: z.string().max(10_000),
    nextSalaryReview: Day.nullable(),
    vacationDaysOverride: z.number().int().min(0).max(60).nullable(),
  })
  .partial();

profileRouter.patch("/:id/profile", async (req, res) => {
  const body = ProfileBody.parse(req.body ?? {});
  await mutate(req.params.id, res, (person) => {
    for (const [key, value] of Object.entries(body)) {
      person.set(key, value === null ? undefined : key === "skills" ? [...new Set(value as string[])] : value);
    }
  });
});

const SalaryBody = z.object({
  amount: z.number().positive().max(100_000_000),
  currency: z.string().trim().length(3).toUpperCase().default("MXN"),
  period: z.enum(["monthly", "biweekly", "weekly", "hourly", "yearly"]).default("monthly"),
  effectiveDate: Day,
  note: Note,
});

profileRouter.post("/:id/salary", async (req, res) => {
  const body = SalaryBody.parse(req.body ?? {});
  await mutate(req.params.id, res, (person) => void person.salaryHistory.push(body), 201);
});

const VacationBody = z
  .object({ startDate: Day, endDate: Day, days: z.number().min(0.5).max(60), note: Note })
  .refine((v) => v.endDate >= v.startDate, { message: "La fecha final es anterior a la inicial", path: ["endDate"] });

profileRouter.post("/:id/vacations", async (req, res) => {
  const body = VacationBody.parse(req.body ?? {});
  await mutate(req.params.id, res, (person) => void person.vacations.push(body), 201);
});

const OvertimeStatus = z.enum(["pending", "paid", "compensated"]);
const OvertimeBody = z.object({
  date: Day,
  hours: z.number().min(0.25).max(24),
  reason: Note,
  projectId: ObjectId.optional(),
  status: OvertimeStatus.default("pending"),
});

profileRouter.post("/:id/overtime", async (req, res) => {
  const body = OvertimeBody.parse(req.body ?? {});
  await mutate(req.params.id, res, (person) => void person.overtime.push(body), 201);
});

profileRouter.patch("/:id/overtime/:entryId", async (req, res) => {
  const { status } = z.object({ status: OvertimeStatus }).parse(req.body ?? {});
  await mutate(req.params.id, res, (person) => {
    const entry = person.overtime.id(req.params.entryId);
    if (!entry) return false;
    entry.status = status;
  });
});

// Con suggestionId confirma (o corrige) una sugerencia de Claude: toma su
// fecha y su sesión, y la quita de las pendientes.
const MoodBody = z.object({
  level: z.number().int().min(1).max(5),
  note: Note,
  date: Day.optional(),
  suggestionId: ObjectId.optional(),
});

profileRouter.post("/:id/moods", async (req, res) => {
  const body = MoodBody.parse(req.body ?? {});
  await mutate(
    req.params.id,
    res,
    (person) => {
      const suggestion = body.suggestionId ? person.moodSuggestions.id(body.suggestionId) : null;
      if (body.suggestionId && !suggestion) return false;
      person.moods.push({
        level: body.level,
        note: body.note ?? suggestion?.evidence ?? undefined,
        date: body.date ?? suggestion?.date ?? startOfDay(),
        sessionId: suggestion?.sessionId,
      });
      suggestion?.deleteOne();
    },
    201,
  );
});

// Borrar una entrada de cualquiera de las listas del perfil.
const LISTS = {
  salary: "salaryHistory",
  vacations: "vacations",
  overtime: "overtime",
  moods: "moods",
  "mood-suggestions": "moodSuggestions",
} as const;

profileRouter.delete("/:id/:list/:entryId", async (req, res, next) => {
  const field = LISTS[req.params.list as keyof typeof LISTS];
  if (!field) {
    next();
    return;
  }
  await mutate(req.params.id, res, (person) => {
    const entry = person[field].id(req.params.entryId);
    if (!entry) return false;
    entry.deleteOne();
  });
});

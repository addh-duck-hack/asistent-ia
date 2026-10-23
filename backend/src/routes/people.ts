import { Router } from "express";
import { Types } from "mongoose";
import { z } from "zod";
import {
  ActionItemModel,
  AnalysisModel,
  OneOnOneModel,
  PersonModel,
  ProjectModel,
  SessionModel,
  TranscriptModel,
} from "../models/index.js";
import { buildOneOnOneInput, generateOneOnOne } from "../llm/oneOnOne.js";
import { cleanAliases, findAliasConflict, linkOwnerItems, normalize, personKeys } from "../utils/people.js";

export const peopleRouter = Router();

const ObjectId = z.string().regex(/^[a-f\d]{24}$/i, "id inválido");
const OPEN = ["open", "in_progress", "blocked"];
const DAY = 86_400_000;

const PersonBody = z.object({
  name: z.string().trim().min(1),
  role: z.string().trim().default(""),
  email: z.string().trim().email().or(z.literal("")).optional(),
  aliases: z.array(z.string()).default([]),
  active: z.boolean().optional(),
  // Proyectos donde participa (se sincroniza con Project.members).
  projectIds: z.array(ObjectId).optional(),
});

async function syncProjects(personId: Types.ObjectId, projectIds: string[]) {
  await ProjectModel.updateMany({ _id: { $in: projectIds } }, { $addToSet: { members: personId } });
  await ProjectModel.updateMany({ _id: { $nin: projectIds }, members: personId }, { $pull: { members: personId } });
}

// Listado del equipo con contadores para la barra lateral.
peopleRouter.get("/", async (req, res) => {
  const includeArchived = req.query.active === "false" || req.query.all === "true";
  const people = await PersonModel.find(includeArchived ? {} : { active: { $ne: false } }).sort({ name: 1 }).lean();
  const ids = people.map((p) => p._id);
  const weekAgo = new Date(Date.now() - 7 * DAY);
  const today = new Date(new Date().setHours(0, 0, 0, 0));

  const [counts, projects] = await Promise.all([
    ActionItemModel.aggregate<{ _id: Types.ObjectId; open: number; blocked: number; overdue: number; doneWeek: number }>([
      { $match: { ownerId: { $in: ids } } },
      {
        $group: {
          _id: "$ownerId",
          open: { $sum: { $cond: [{ $in: ["$status", OPEN] }, 1, 0] } },
          blocked: { $sum: { $cond: [{ $eq: ["$status", "blocked"] }, 1, 0] } },
          overdue: {
            // $gt null: un campo ausente no es null en agregaciones; sin esto los
            // pendientes sin fecha contarían como vencidos.
            $sum: { $cond: [{ $and: [{ $in: ["$status", OPEN] }, { $gt: ["$dueDate", null] }, { $lt: ["$dueDate", today] }] }, 1, 0] },
          },
          doneWeek: { $sum: { $cond: [{ $and: [{ $eq: ["$status", "done"] }, { $gte: ["$updatedAt", weekAgo] }] }, 1, 0] } },
        },
      },
    ]),
    ProjectModel.find({ members: { $in: ids } }).select({ name: 1, members: 1 }).lean(),
  ]);
  const byPerson = new Map(counts.map((c) => [String(c._id), c]));

  res.json(
    people.map((p) => {
      const c = byPerson.get(String(p._id));
      return {
        ...p,
        projects: projects.filter((pr) => pr.members.some((m) => String(m) === String(p._id))).map((pr) => ({ _id: pr._id, name: pr.name })),
        counts: { open: c?.open ?? 0, blocked: c?.blocked ?? 0, overdue: c?.overdue ?? 0, doneWeek: c?.doneWeek ?? 0 },
      };
    }),
  );
});

peopleRouter.post("/", async (req, res) => {
  const body = PersonBody.parse(req.body ?? {});
  const aliases = cleanAliases(body.name, body.aliases);
  const conflict = await findAliasConflict(body.name, aliases);
  if (conflict) {
    res.status(409).json({ error: "alias_conflict", message: `"${conflict.alias}" ya es de ${conflict.person}.` });
    return;
  }
  const person = await PersonModel.create({ name: body.name, role: body.role, email: body.email || undefined, aliases });
  if (body.projectIds) await syncProjects(person._id, body.projectIds);
  const linked = await linkOwnerItems(String(person._id));
  res.status(201).json({ ...person.toObject(), linkedItems: linked });
});

peopleRouter.patch("/:id", async (req, res) => {
  const body = PersonBody.partial().parse(req.body ?? {});
  const person = await PersonModel.findById(req.params.id);
  if (!person) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  const name = body.name ?? person.name;
  const aliases = body.aliases ? cleanAliases(name, body.aliases) : person.aliases;
  if (body.name !== undefined || body.aliases !== undefined) {
    const conflict = await findAliasConflict(name, aliases, String(person._id));
    if (conflict) {
      res.status(409).json({ error: "alias_conflict", message: `"${conflict.alias}" ya es de ${conflict.person}.` });
      return;
    }
  }
  person.name = name;
  person.aliases = aliases;
  if (body.role !== undefined) person.role = body.role;
  if (body.email !== undefined) person.email = body.email || undefined;
  if (body.active !== undefined) person.active = body.active;
  await person.save();
  if (body.projectIds) await syncProjects(person._id, body.projectIds);
  const linked = person.active ? await linkOwnerItems(String(person._id)) : 0;
  res.json({ ...person.toObject(), linkedItems: linked });
});

// Avance del periodo: qué cerró, qué se le asignó, qué lleva estancado.
peopleRouter.get("/:id/progress", async (req, res) => {
  const id = ObjectId.parse(req.params.id);
  const days = z.coerce.number().int().min(1).max(90).default(7).parse(req.query.days);
  const since = new Date(Date.now() - days * DAY);
  const stalledBefore = new Date(Date.now() - 7 * DAY);
  const today = new Date(new Date().setHours(0, 0, 0, 0));
  const items = await ActionItemModel.find({ ownerId: id })
    .populate("projectId", "name")
    .populate("sessionId", "title date")
    .sort({ updatedAt: -1 })
    .lean();

  const lastChange = (i: (typeof items)[number]) =>
    i.history.length ? Math.max(...i.history.map((h) => new Date(h.at ?? 0).getTime())) : (i.createdAt as Date).getTime();
  const open = items.filter((i) => OPEN.includes(i.status));

  res.json({
    days,
    completed: items.filter((i) => i.status === "done" && (i.updatedAt as Date) >= since),
    assigned: items.filter((i) => (i.createdAt as Date) >= since),
    stalled: open.filter((i) => i.status !== "blocked" && lastChange(i) < stalledBefore.getTime()),
    blocked: open.filter((i) => i.status === "blocked"),
    overdue: open.filter((i) => i.dueDate && i.dueDate < today),
  });
});

const escapeRegex = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Regex que ignora acentos: "Ramírez" también encuentra "Ramirez".
function accentInsensitive(word: string): string {
  const groups: Record<string, string> = { a: "[aáàä]", e: "[eéèë]", i: "[iíìï]", o: "[oóòö]", u: "[uúùü]", n: "[nñ]" };
  return [...normalize(word)].map((ch) => groups[ch] ?? escapeRegex(ch)).join("");
}

// Sesiones donde participó o se le nombró (por nombre, primer nombre o alias).
peopleRouter.get("/:id/mentions", async (req, res) => {
  const person = await PersonModel.findById(ObjectId.parse(req.params.id)).lean();
  if (!person) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  const alternatives = personKeys(person).map(accentInsensitive).join("|");
  // Mongo hace una búsqueda amplia; el filtro por palabra completa (que "Ana" no
  // coincida dentro de "mañana") se aplica aquí con Unicode.
  const broad = new RegExp(alternatives, "i");
  const pattern = new RegExp(`(^|[^\\p{L}])(${alternatives})(?=$|[^\\p{L}])`, "iu");

  const [byParticipant, byText] = await Promise.all([
    SessionModel.find({ participants: { $in: [person.name, ...(person.aliases ?? [])] } }).select({ _id: 1 }).lean(),
    TranscriptModel.find({ text: broad }).select({ sessionId: 1, text: 1 }).lean(),
  ]);
  const snippets = new Map<string, string>();
  for (const t of byText) {
    const m = pattern.exec(t.text);
    if (!m) continue;
    const start = Math.max(0, m.index - 120);
    const end = Math.min(t.text.length, m.index + m[0].length + 120);
    snippets.set(String(t.sessionId), `${start > 0 ? "…" : ""}${t.text.slice(start, end).trim()}${end < t.text.length ? "…" : ""}`);
  }
  const ids = [...new Set([...byParticipant.map((s) => String(s._id)), ...snippets.keys()])];
  const sessions = await SessionModel.find({ _id: { $in: ids } }).populate("projectId", "name").sort({ date: -1 }).limit(30).lean();
  const summaries = await AnalysisModel.find({ sessionId: { $in: sessions.map((s) => s._id) } })
    .sort({ createdAt: 1 })
    .select({ sessionId: 1, summaryText: 1 })
    .lean();
  const summaryBySession = new Map(summaries.map((a) => [String(a.sessionId), a.summaryText]));

  res.json(
    sessions.map((s) => ({
      session: { _id: s._id, title: s.title, date: s.date, type: s.type, project: s.projectId },
      snippet: snippets.get(String(s._id)) ?? null,
      summary: summaryBySession.get(String(s._id)) ?? null,
    })),
  );
});

// Preparación del 1:1: historial y "Preparar 1:1" (llamada inmediata a Claude).
peopleRouter.get("/:id/one-on-ones", async (req, res) => {
  const personId = ObjectId.parse(req.params.id);
  res.json(await OneOnOneModel.find({ personId }).sort({ createdAt: -1 }).limit(20).lean());
});

peopleRouter.post("/:id/one-on-ones", async (req, res) => {
  const personId = ObjectId.parse(req.params.id);
  const { days } = z.object({ days: z.number().int().min(1).max(60).default(14) }).parse(req.body ?? {});
  const input = await buildOneOnOneInput(personId, days);
  if (!input) {
    res.status(404).json({ error: "not_found", message: "La persona no existe." });
    return;
  }
  const out = await generateOneOnOne(input);
  const prep = await OneOnOneModel.create({
    personId,
    periodStart: input.periodStart,
    periodEnd: input.periodEnd,
    result: out.result,
    model: out.model,
    effort: out.effort,
    promptVersion: out.promptVersion,
    usage: out.usage,
  });
  res.status(201).json(prep);
});

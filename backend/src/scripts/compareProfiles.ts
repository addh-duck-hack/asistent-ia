// Compara modelos/effort sobre sesiones reales, SIN guardar nada en Mongo.
// Cada combinación es una llamada real a Claude (cuesta dinero).
//
//   docker compose exec -T worker node dist/scripts/compareProfiles.js > comparacion.md
//   ... --last 3                         (las 3 sesiones más recientes; default)
//   ... --sessions <id>,<id>             (sesiones concretas)
//   ... --configs haiku:low:quick,opus:high:deep
//
// Formato de cada config: modelo:effort:nivel. Alias: haiku, sonnet, opus.
import mongoose from "mongoose";
import { AnalysisDepth, type Analysis } from "@asistent-ia/schema";
import { connectMongo } from "../db.js";
import { analyzeTranscript, type AnalyzeOutput } from "../llm/analyze.js";
import type { AnalysisProfile, Effort } from "../llm/profiles.js";
import { ProjectModel, SessionModel, TranscriptModel } from "../models/index.js";

const MODEL_ALIASES: Record<string, string> = {
  haiku: "claude-haiku-5-5",
  sonnet: "claude-sonnet-5-5",
  opus: "claude-opus-5-5",
};
const DEFAULT_CONFIGS = "haiku:low:quick,sonnet:medium:standard,opus:medium:standard,opus:high:deep";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function parseConfigs(raw: string): AnalysisProfile[] {
  return raw.split(",").map((c) => {
    const [m, effort, depth] = c.trim().split(":");
    if (!m || !effort || !depth) throw new Error(`Config inválida "${c}" (usa modelo:effort:nivel)`);
    return {
      depth: AnalysisDepth.parse(depth),
      label: c.trim(),
      description: "",
      model: MODEL_ALIASES[m] ?? m,
      effort: effort as Effort,
    };
  });
}

const log = (msg: string) => process.stderr.write(`${msg}\n`);
const usd = (n: number | null) => (n == null ? "?" : `$${n.toFixed(4)}`);

function renderResult(r: Analysis): string {
  const lines = [`> ${r.summary.executive}`, ""];
  const list = (title: string, items: string[]) => {
    if (items.length === 0) return;
    lines.push(`**${title} (${items.length})**`, ...items.map((i) => `- ${i}`), "");
  };
  list("Decisiones", r.decisions.map((d) => d.decision));
  list(
    "Action items",
    r.action_items.map((a) => `${a.task} — ${a.owner ?? "sin responsable"}${a.due_date ? `, ${a.due_date}` : ""} (${a.priority})`),
  );
  list("Bloqueos", r.blockers.map((b) => `${b.description} (${b.severity})`));
  list("Riesgos", r.risks.map((x) => `${x.description} (${x.severity})`));
  list("Preguntas abiertas", r.open_questions);
  list("Temas", r.topics.map((t) => `${t.title}: ${t.key_points.join("; ")}`));
  return lines.join("\n");
}

await connectMongo();
const configs = parseConfigs(arg("configs") ?? DEFAULT_CONFIGS);
const ids = arg("sessions")?.split(",");
const sessions = ids
  ? await SessionModel.find({ _id: { $in: ids } }).lean()
  : await SessionModel.find().sort({ createdAt: -1 }).limit(Number(arg("last") ?? 3)).lean();

log(`${sessions.length} sesiones × ${configs.length} configs = ${sessions.length * configs.length} llamadas a Claude`);

const out: string[] = ["# Comparación de niveles de análisis", "", `Generado: ${new Date().toISOString()}`, ""];
const totals = new Map<string, { usd: number; secs: number }>();

for (const session of sessions) {
  const [transcript, project] = await Promise.all([
    TranscriptModel.findOne({ sessionId: session._id }).lean(),
    ProjectModel.findById(session.projectId).populate<{ members: { name: string; aliases: string[] }[] }>("members").lean(),
  ]);
  if (!transcript || !project) {
    log(`- ${session._id}: sin transcripción o proyecto, se omite`);
    continue;
  }

  out.push(`## ${session.title} (${session.date.toISOString().slice(0, 10)}, ${transcript.text.length} caracteres)`, "");
  const rows: string[] = ["| Config | Modelo | Entrada | Salida | Costo | Tiempo |", "|---|---|---|---|---|---|"];
  const details: string[] = [];

  for (const profile of configs) {
    log(`- ${session.title} · ${profile.label}…`);
    const started = Date.now();
    let res: AnalyzeOutput;
    try {
      res = await analyzeTranscript(
        {
          depth: profile.depth,
          project: {
            name: project.name,
            description: project.description ?? "",
            context: project.context ?? "",
            members: project.members.map((m) => ({ name: m.name, aliases: m.aliases ?? [] })),
          },
          session: { type: session.type, title: session.title, date: session.date, participants: session.participants },
          transcript: { text: transcript.text, segments: transcript.segments },
          // Sin pendientes: misma entrada para todas las configs.
          openItems: [],
        },
        undefined,
        profile,
      );
    } catch (err) {
      rows.push(`| ${profile.label} | — | — | — | error | — |`);
      details.push(`### ${profile.label}`, "", `Error: ${err instanceof Error ? err.message : String(err)}`, "");
      continue;
    }
    const secs = (Date.now() - started) / 1000;
    const u = res.usage;
    rows.push(
      `| ${profile.label} | ${res.model} | ${u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens} | ${u.outputTokens} | ${usd(u.costUsd)} | ${secs.toFixed(0)} s |`,
    );
    details.push(`### ${profile.label}`, "", renderResult(res.result), "");
    const t = totals.get(profile.label) ?? { usd: 0, secs: 0 };
    totals.set(profile.label, { usd: t.usd + (u.costUsd ?? 0), secs: t.secs + secs });
  }
  out.push(...rows, "", ...details);
}

out.push("## Totales", "", "| Config | Costo total | Tiempo total |", "|---|---|---|");
for (const [label, t] of totals) out.push(`| ${label} | ${usd(t.usd)} | ${t.secs.toFixed(0)} s |`);
const grand = [...totals.values()].reduce((s, t) => s + t.usd, 0);
out.push("", `Costo de esta comparación: ${usd(grand)}`);

console.log(out.join("\n"));
log(`Listo. Costo total ≈ ${usd(grand)}`);
await mongoose.disconnect();

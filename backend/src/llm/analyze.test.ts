import { describe, expect, it } from "vitest";
import { buildAnalysisRequest, formatTranscript, type AnalyzeInput } from "./analyze.js";
import { ANALYSIS_SYSTEM_PROMPT } from "./prompts/analysis.js";

const input: AnalyzeInput = {
  project: { name: "Portal", description: "Portal de clientes", context: "React + Node", members: ["Ana", "Carlos"] },
  session: { type: "meeting", title: "Daily", date: new Date("2026-10-22T15:00:00Z"), participants: [] },
  transcript: {
    text: "",
    segments: [
      { startSec: 0, speaker: "me", text: "¿Cómo van?" },
      { startSec: 3725, speaker: "others", text: "Bien." },
    ],
  },
  openItems: [{ id: "abc123", task: "Migrar la base", owner: "Carlos", status: "open" }],
};

describe("buildAnalysisRequest", () => {
  it("usa el modelo, effort, fallback y formato estructurado", () => {
    const req = buildAnalysisRequest(input);
    expect(req.model).toBe("claude-opus-5-5");
    expect(req.thinking).toEqual({ type: "adaptive" });
    expect(req.output_config.effort).toBe("high");
    expect(req.output_config.format).toBeDefined();
    expect(req.betas).toEqual(["server-side-fallback-2026-07-01"]);
    expect(req.fallbacks).toBe("default");
  });

  it("pone lo estable primero con cache_control y lo variable al final", () => {
    const req = buildAnalysisRequest(input);
    expect(req.system[0]!.text).toBe(ANALYSIS_SYSTEM_PROMPT);
    expect(req.system[0]!.cache_control).toEqual({ type: "ephemeral" });
    const [project, session] = req.messages[0]!.content;
    expect(project!.text).toContain("Nombre: Portal");
    expect(project!.cache_control).toEqual({ type: "ephemeral" });
    expect(project!.text).not.toContain("Migrar la base");
    expect(session!.text).toContain("[abc123] Migrar la base (responsable: Carlos)");
    expect(session!.text).toContain("Fecha: 2026-10-22");
  });

  it("el bloque del proyecto no cambia entre sesiones distintas (caché)", () => {
    const other = { ...input, session: { ...input.session, title: "Planning" }, openItems: [] };
    expect(buildAnalysisRequest(other).messages[0]!.content[0]!.text).toBe(
      buildAnalysisRequest(input).messages[0]!.content[0]!.text,
    );
  });
});

describe("formatTranscript", () => {
  it("formatea segmentos con tiempo y etiqueta de canal", () => {
    expect(formatTranscript(input.transcript)).toBe("[00:00:00] Yo: ¿Cómo van?\n[01:02:05] Otros: Bien.");
  });

  it("usa el texto plano si no hay segmentos", () => {
    expect(formatTranscript({ text: "hola", segments: [] })).toBe("hola");
  });
});

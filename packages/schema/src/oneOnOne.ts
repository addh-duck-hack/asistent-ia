import { z } from "zod";

// Preparación del 1:1 del líder con una persona del equipo.
export const OneOnOne = z.object({
  // 2 a 4 frases: cómo le está yendo y qué conviene hablar.
  summary: z.string(),
  wins: z.array(z.string()),
  blockers: z.array(z.string()),
  // Señales de carga, ánimo o dependencias, con lenguaje prudente; null si no hay evidencia.
  workload_signals: z.string().nullable(),
  topics: z.array(z.string()),
  questions: z.array(z.string()),
});

export type OneOnOne = z.infer<typeof OneOnOne>;

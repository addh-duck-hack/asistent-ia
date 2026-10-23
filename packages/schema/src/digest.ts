import { z } from "zod";

// Resumen semanal de un proyecto: se arma con los análisis de la semana (no con
// las transcripciones) y el estado de los pendientes.

export const Digest = z.object({
  // 3 a 6 frases: cómo va el proyecto y qué requiere atención del líder.
  summary: z.string(),
  highlights: z.array(z.string()),
  decisions: z.array(z.object({ decision: z.string(), session: z.string() })),
  completed: z.array(z.string()),
  // Pendientes que requieren atención: vencidos, bloqueados, sin responsable o estancados.
  attention: z.array(
    z.object({
      task: z.string(),
      owner: z.string().nullable(),
      reason: z.string(),
    }),
  ),
  risks: z.array(z.object({ description: z.string(), severity: z.enum(["low", "medium", "high"]) })),
  next_week_focus: z.array(z.string()),
});

export type Digest = z.infer<typeof Digest>;

import "dotenv/config";
import { z } from "zod";

// dotenv solo aplica en desarrollo local: en Docker las variables ya vienen de
// env_file (backend/.env) y dotenv no las pisa.
const Effort = z.enum(["low", "medium", "high", "xhigh", "max"]);

const Env = z.object({
  PORT: z.coerce.number().default(5000),
  MONGO_URL: z.string().min(1, "Falta MONGO_URL"),
  API_TOKEN: z.string().min(32, "API_TOKEN debe tener al menos 32 caracteres"),
  ANTHROPIC_API_KEY: z.string().optional(),
  // Solo para llaves de organización que no están ligadas a un workspace.
  ANTHROPIC_WORKSPACE_ID: z.string().optional(),
  ENCRYPTION_KEY: z.string().optional(),
  MS_CLIENT_ID: z.string().optional(),
  MS_CLIENT_SECRET: z.string().optional(),
  MS_TENANT_ID: z.string().optional(),
  MS_REDIRECT_URI: z.string().optional(),
  NOTION_TOKEN: z.string().optional(),
  BACKEND_PUBLIC_URL: z.string().optional(),
  // Modelo y effort de cada nivel de análisis (ver llm/profiles.ts).
  // Rápido usa Sonnet/medium: en las pruebas, Haiku (low y medium) y Sonnet
  // en low no detectaron quién asumió cada tarea; quick y standard solo se
  // distinguen por la extensión que pide el prompt.
  ANALYSIS_QUICK_MODEL: z.string().default("claude-sonnet-5-5"),
  ANALYSIS_QUICK_EFFORT: Effort.default("medium"),
  ANALYSIS_STANDARD_MODEL: z.string().default("claude-sonnet-5-5"),
  ANALYSIS_STANDARD_EFFORT: Effort.default("medium"),
  ANALYSIS_DEEP_MODEL: z.string().default("claude-opus-5-5"),
  ANALYSIS_DEEP_EFFORT: Effort.default("high"),
  SCHEDULER_ENABLED: z
    .string()
    .optional()
    .transform((v) => v === "true"),
});

export const config = Env.parse(process.env);

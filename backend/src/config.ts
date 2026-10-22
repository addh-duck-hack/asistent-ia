import "dotenv/config";
import { z } from "zod";

// dotenv solo aplica en desarrollo local: en Docker las variables ya vienen de
// env_file (backend/.env) y dotenv no las pisa.
const Env = z.object({
  PORT: z.coerce.number().default(5000),
  MONGO_URL: z.string().min(1, "Falta MONGO_URL"),
  API_TOKEN: z.string().min(32, "API_TOKEN debe tener al menos 32 caracteres"),
  ANTHROPIC_API_KEY: z.string().optional(),
  ENCRYPTION_KEY: z.string().optional(),
  MS_CLIENT_ID: z.string().optional(),
  MS_CLIENT_SECRET: z.string().optional(),
  MS_TENANT_ID: z.string().optional(),
  MS_REDIRECT_URI: z.string().optional(),
  NOTION_TOKEN: z.string().optional(),
  BACKEND_PUBLIC_URL: z.string().optional(),
  SCHEDULER_ENABLED: z
    .string()
    .optional()
    .transform((v) => v === "true"),
});

export const config = Env.parse(process.env);

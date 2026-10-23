import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";

let client: Anthropic | undefined;

// Solo el worker llama a Claude; el API arranca aunque falte la llave.
export function getClaude(): Anthropic {
  if (!config.ANTHROPIC_API_KEY) throw new Error("Falta ANTHROPIC_API_KEY en backend/.env");
  // El SDK ya reintenta 408/409/429/5xx y errores de conexión.
  client ??= new Anthropic({
    apiKey: config.ANTHROPIC_API_KEY,
    maxRetries: 4,
    defaultHeaders: config.ANTHROPIC_WORKSPACE_ID
      ? { "anthropic-workspace-id": config.ANTHROPIC_WORKSPACE_ID }
      : undefined,
  });
  return client;
}

// Precios de lista en USD por millón de tokens (API de Anthropic). Sirven para
// mostrar un costo estimado por análisis; la factura real está en la Console.
// Escrituras de caché de 5 min = 1.25x la entrada; lecturas ≈ 0.1x.
interface Rate {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

const rate = (input: number, output: number, cacheRead = input * 0.1): Rate => ({
  input,
  output,
  cacheRead,
  cacheWrite: input * 1.25,
});

const PRICES: Record<string, Rate> = {
  "claude-opus-5-5": rate(4, 20, 0.2),
  "claude-sonnet-5-5": rate(2, 10, 0.2),
  "claude-haiku-5-5": rate(0.1, 0.5),
  // Posibles modelos de respaldo cuando actúa `fallbacks: "default"`.
  "claude-opus-5": rate(5, 25),
  "claude-opus-4-8": rate(5, 25),
};

// Haiku 5.5 cobra otra tarifa cuando el prompt pasa de 100K tokens.
const HAIKU_LONG = rate(0.5, 2.5);

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens: number;
  cacheCreationInputTokens: number;
}

/** Costo estimado en USD, o null si el modelo no está en la tabla. */
export function estimateCostUsd(model: string, u: TokenUsage): number | null {
  const promptTokens = u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens;
  const p = model === "claude-haiku-5-5" && promptTokens > 100_000 ? HAIKU_LONG : PRICES[model];
  if (!p) return null;
  const usd =
    (u.inputTokens * p.input +
      u.outputTokens * p.output +
      u.cacheReadInputTokens * p.cacheRead +
      u.cacheCreationInputTokens * p.cacheWrite) /
    1_000_000;
  return Math.round(usd * 1_000_000) / 1_000_000;
}

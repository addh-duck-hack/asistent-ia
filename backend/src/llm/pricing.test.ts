import { describe, expect, it } from "vitest";
import { estimateCostUsd } from "./pricing.js";

const usage = { inputTokens: 5_000, outputTokens: 10_000, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 };

describe("estimateCostUsd", () => {
  it("calcula con los precios de lista de cada modelo", () => {
    expect(estimateCostUsd("claude-opus-5-5", usage)).toBeCloseTo(0.22, 6); // 5k×4 + 10k×20
    expect(estimateCostUsd("claude-sonnet-5-5", usage)).toBeCloseTo(0.11, 6);
    expect(estimateCostUsd("claude-haiku-5-5", usage)).toBeCloseTo(0.0055, 6);
  });

  it("cobra la caché aparte", () => {
    const cached = { inputTokens: 1_000, outputTokens: 0, cacheReadInputTokens: 2_000, cacheCreationInputTokens: 2_000 };
    expect(estimateCostUsd("claude-opus-5-5", cached)).toBeCloseTo((1_000 * 4 + 2_000 * 0.2 + 2_000 * 5) / 1e6, 6);
  });

  it("usa la tarifa larga de Haiku por encima de 100K tokens de prompt", () => {
    const long = { inputTokens: 120_000, outputTokens: 1_000, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 };
    expect(estimateCostUsd("claude-haiku-5-5", long)).toBeCloseTo((120_000 * 0.5 + 1_000 * 2.5) / 1e6, 6);
  });

  it("devuelve null para un modelo desconocido", () => {
    expect(estimateCostUsd("claude-desconocido", usage)).toBeNull();
  });
});

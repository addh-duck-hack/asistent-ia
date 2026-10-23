import type Anthropic from "@anthropic-ai/sdk";
import { getClaude } from "../llm/client.js";
import { buildDigestBatchParams, buildDigestInput, parseBatchDigest } from "../llm/digest.js";
import { estimateCostUsd } from "../llm/pricing.js";
import { getProfile } from "../llm/profiles.js";
import { DIGEST_PROMPT_VERSION } from "../llm/prompts/digest.js";
import { DigestBatchModel, DigestModel, SessionModel } from "../models/index.js";

export const WEEKLY_DIGEST_JOB = "weekly-digest";
export const POLL_DIGEST_BATCHES_JOB = "poll-digest-batches";

/**
 * Lunes 8:00: un resumen por cada proyecto con sesiones en los últimos 7 días,
 * todos en un solo lote de la Batch API (50% más barato; no hay prisa).
 */
export async function runWeeklyDigest(now = new Date(), client: Anthropic = getClaude()) {
  const periodEnd = now;
  const periodStart = new Date(now.getTime() - 7 * 86_400_000);
  const projectIds: string[] = (
    await SessionModel.distinct("projectId", { status: "done", date: { $gte: periodStart, $lte: periodEnd } })
  ).map(String);

  const inputs = (await Promise.all(projectIds.map((id) => buildDigestInput(id, periodStart, periodEnd)))).filter(
    (i) => i !== null,
  );
  if (inputs.length === 0) {
    console.log("[digest] sin sesiones en la semana; no se envía lote");
    return;
  }

  const profile = getProfile("standard");
  const batch = await client.messages.batches.create({
    requests: inputs.map((input) => ({
      custom_id: `digest-${input.projectId}`,
      params: buildDigestBatchParams(input, profile),
    })),
  });
  await DigestBatchModel.create({
    batchId: batch.id,
    model: profile.model,
    effort: profile.effort,
    requests: inputs.map((i) => ({
      customId: `digest-${i.projectId}`,
      projectId: i.projectId,
      periodStart: i.periodStart,
      periodEnd: i.periodEnd,
      sessionCount: i.sessionCount,
    })),
  });
  console.log(`[digest] lote ${batch.id} enviado con ${inputs.length} proyectos`);
}

/** Revisa los lotes pendientes y guarda los resúmenes de los que ya terminaron. */
export async function pollDigestBatches(client: Anthropic = getClaude()) {
  const pending = await DigestBatchModel.find({ status: "pending" });
  for (const doc of pending) {
    const batch = await client.messages.batches.retrieve(doc.batchId);
    if (batch.processing_status !== "ended") continue;

    const failures: string[] = [];
    for await (const item of await client.messages.batches.results(doc.batchId)) {
      const req = doc.requests.find((r) => r.customId === item.custom_id);
      if (!req) continue;
      if (item.result.type !== "succeeded") {
        failures.push(`${item.custom_id}: ${item.result.type}`);
        continue;
      }
      const message = item.result.message;
      try {
        const cost = estimateCostUsd(message.model, {
          inputTokens: message.usage.input_tokens,
          outputTokens: message.usage.output_tokens,
          cacheReadInputTokens: message.usage.cache_read_input_tokens ?? 0,
          cacheCreationInputTokens: message.usage.cache_creation_input_tokens ?? 0,
        });
        await DigestModel.create({
          projectId: req.projectId,
          periodStart: req.periodStart,
          periodEnd: req.periodEnd,
          sessionCount: req.sessionCount,
          result: parseBatchDigest(message),
          source: "scheduled",
          model: message.model,
          effort: doc.effort,
          promptVersion: DIGEST_PROMPT_VERSION,
          usage: {
            inputTokens: message.usage.input_tokens,
            outputTokens: message.usage.output_tokens,
            // La Batch API cobra la mitad.
            costUsd: cost == null ? null : cost / 2,
          },
        });
      } catch (err) {
        failures.push(`${item.custom_id}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    doc.status = failures.length === doc.requests.length ? "failed" : "done";
    if (failures.length) doc.error = failures.join("; ");
    await doc.save();
    console.log(`[digest] lote ${doc.batchId} terminado${failures.length ? ` con ${failures.length} errores` : ""}`);
  }
}

import { Schema, model, type InferSchemaType } from "mongoose";

const analysisSchema = new Schema(
  {
    sessionId: { type: Schema.Types.ObjectId, ref: "Session", required: true, index: true },
    // Resultado validado contra Analysis de @asistent-ia/schema.
    result: { type: Schema.Types.Mixed, required: true },
    // Copia del resumen ejecutivo para el índice de texto.
    summaryText: { type: String, default: "" },
    depth: { type: String },
    model: { type: String, required: true },
    effort: { type: String },
    promptVersion: { type: String, required: true },
    usage: {
      inputTokens: Number,
      outputTokens: Number,
      cacheReadInputTokens: Number,
      cacheCreationInputTokens: Number,
      // Estimado con precios de lista (llm/pricing.ts).
      costUsd: Number,
    },
  },
  { timestamps: true },
);

analysisSchema.index({ summaryText: "text" }, { default_language: "spanish" });

export type Analysis = InferSchemaType<typeof analysisSchema>;
export const AnalysisModel = model("Analysis", analysisSchema);

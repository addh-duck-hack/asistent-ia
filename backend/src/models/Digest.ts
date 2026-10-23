import { Schema, model, type InferSchemaType } from "mongoose";

const digestSchema = new Schema(
  {
    projectId: { type: Schema.Types.ObjectId, ref: "Project", required: true },
    periodStart: { type: Date, required: true },
    periodEnd: { type: Date, required: true },
    // Resultado validado contra Digest de @asistent-ia/schema.
    result: { type: Schema.Types.Mixed, required: true },
    sessionCount: { type: Number, required: true },
    // scheduled: job de los lunes (Batch API) · manual: botón "Generar ahora".
    source: { type: String, enum: ["scheduled", "manual"], required: true },
    model: { type: String, required: true },
    effort: { type: String },
    promptVersion: { type: String, required: true },
    usage: {
      inputTokens: Number,
      outputTokens: Number,
      costUsd: Number,
    },
  },
  { timestamps: true },
);

digestSchema.index({ projectId: 1, periodEnd: -1 });

export type Digest = InferSchemaType<typeof digestSchema>;
export const DigestModel = model("Digest", digestSchema);

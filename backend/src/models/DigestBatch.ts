import { Schema, model, type InferSchemaType } from "mongoose";

// Lote enviado a la Message Batches API por el job semanal; el job
// poll-digest-batches lo revisa hasta que termina y guarda los Digest.
const digestBatchSchema = new Schema(
  {
    batchId: { type: String, required: true, unique: true },
    status: { type: String, enum: ["pending", "done", "failed"], default: "pending" },
    model: { type: String, required: true },
    effort: { type: String },
    requests: [
      {
        _id: false,
        customId: { type: String, required: true },
        projectId: { type: Schema.Types.ObjectId, ref: "Project", required: true },
        periodStart: { type: Date, required: true },
        periodEnd: { type: Date, required: true },
        sessionCount: { type: Number, required: true },
      },
    ],
    error: String,
  },
  { timestamps: true },
);

export type DigestBatch = InferSchemaType<typeof digestBatchSchema>;
export const DigestBatchModel = model("DigestBatch", digestBatchSchema);

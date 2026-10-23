import { Schema, model, type InferSchemaType } from "mongoose";

const oneOnOneSchema = new Schema(
  {
    personId: { type: Schema.Types.ObjectId, ref: "Person", required: true, index: true },
    periodStart: { type: Date, required: true },
    periodEnd: { type: Date, required: true },
    // Resultado validado contra OneOnOne de @asistent-ia/schema.
    result: { type: Schema.Types.Mixed, required: true },
    model: { type: String, required: true },
    effort: { type: String },
    promptVersion: { type: String, required: true },
    usage: { inputTokens: Number, outputTokens: Number, costUsd: Number },
  },
  { timestamps: true },
);

export type OneOnOne = InferSchemaType<typeof oneOnOneSchema>;
export const OneOnOneModel = model("OneOnOne", oneOnOneSchema);

import { Schema, model, type InferSchemaType } from "mongoose";

const integrationTokenSchema = new Schema(
  {
    provider: { type: String, enum: ["microsoft", "notion"], required: true, unique: true },
    // Cifrado con AES-256-GCM usando ENCRYPTION_KEY antes de guardarse (Fase 4).
    encrypted: { type: String, required: true },
    expiresAt: { type: Date },
  },
  { timestamps: true },
);

export type IntegrationToken = InferSchemaType<typeof integrationTokenSchema>;
export const IntegrationTokenModel = model("IntegrationToken", integrationTokenSchema);

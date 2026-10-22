import { Schema, model, type InferSchemaType } from "mongoose";

const personSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    email: { type: String, trim: true, lowercase: true },
    role: { type: String, default: "" },
    // Variantes con las que aparece en transcripciones/Teams ("Juan", "JP", ...).
    aliases: [{ type: String, trim: true }],
  },
  { timestamps: true },
);

export type Person = InferSchemaType<typeof personSchema>;
export const PersonModel = model("Person", personSchema);

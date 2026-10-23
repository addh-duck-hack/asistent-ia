import { Schema, model, type InferSchemaType } from "mongoose";

const projectSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    description: { type: String, default: "" },
    // Contexto que se le pasa a Claude en cada análisis (stack, objetivos, etc.).
    context: { type: String, default: "" },
    members: [{ type: Schema.Types.ObjectId, ref: "Person" }],
    // Términos que la transcripción suele confundir ("Toks", "Landing"): se le
    // dan a Whisper como pista y a Claude para escribirlos bien.
    vocabulary: [{ type: String, trim: true }],
    archived: { type: Boolean, default: false },
  },
  { timestamps: true },
);

export type Project = InferSchemaType<typeof projectSchema>;
export const ProjectModel = model("Project", projectSchema);

import { Schema, model, type InferSchemaType } from "mongoose";

const projectSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    description: { type: String, default: "" },
    // Contexto que se le pasa a Claude en cada análisis (stack, objetivos, etc.).
    context: { type: String, default: "" },
    members: [{ type: Schema.Types.ObjectId, ref: "Person" }],
    archived: { type: Boolean, default: false },
  },
  { timestamps: true },
);

export type Project = InferSchemaType<typeof projectSchema>;
export const ProjectModel = model("Project", projectSchema);

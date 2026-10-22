import { Schema, model, type InferSchemaType } from "mongoose";

const actionItemSchema = new Schema(
  {
    projectId: { type: Schema.Types.ObjectId, ref: "Project", required: true },
    sessionId: { type: Schema.Types.ObjectId, ref: "Session", required: true },
    task: { type: String, required: true },
    owner: { type: String },
    ownerId: { type: Schema.Types.ObjectId, ref: "Person" },
    dueDate: { type: Date },
    priority: { type: String, enum: ["low", "medium", "high"], default: "medium" },
    status: {
      type: String,
      enum: ["open", "in_progress", "blocked", "done"],
      default: "open",
    },
    // Notas que agrega Claude al detectar avances en sesiones posteriores.
    history: [
      {
        sessionId: { type: Schema.Types.ObjectId, ref: "Session" },
        status: String,
        note: String,
        at: { type: Date, default: Date.now },
      },
    ],
  },
  { timestamps: true },
);

actionItemSchema.index({ projectId: 1, status: 1 });

export type ActionItem = InferSchemaType<typeof actionItemSchema>;
export const ActionItemModel = model("ActionItem", actionItemSchema);

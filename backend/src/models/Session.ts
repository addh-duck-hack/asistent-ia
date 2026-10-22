import { Schema, model, type InferSchemaType } from "mongoose";
import { SessionType } from "@asistent-ia/schema";

const sessionSchema = new Schema(
  {
    projectId: { type: Schema.Types.ObjectId, ref: "Project", required: true },
    type: { type: String, enum: SessionType.options, required: true },
    title: { type: String, required: true, trim: true },
    date: { type: Date, required: true },
    durationSec: { type: Number },
    participants: [{ type: String }],
    status: {
      type: String,
      enum: ["pending", "analyzing", "done", "failed"],
      default: "pending",
    },
    error: { type: String },
  },
  { timestamps: true },
);

sessionSchema.index({ projectId: 1, date: -1 });

export type Session = InferSchemaType<typeof sessionSchema>;
export const SessionModel = model("Session", sessionSchema);

import { Schema, model, type InferSchemaType } from "mongoose";

const segmentSchema = new Schema(
  {
    startSec: Number,
    endSec: Number,
    // "me" = micrófono, "others" = audio del sistema; o nombre si hay diarización.
    speaker: String,
    text: { type: String, required: true },
  },
  { _id: false },
);

const transcriptSchema = new Schema(
  {
    sessionId: { type: Schema.Types.ObjectId, ref: "Session", required: true, unique: true },
    segments: [segmentSchema],
    text: { type: String, required: true },
    language: { type: String, default: "es" },
  },
  { timestamps: true },
);

transcriptSchema.index({ text: "text" }, { default_language: "spanish" });

export type Transcript = InferSchemaType<typeof transcriptSchema>;
export const TranscriptModel = model("Transcript", transcriptSchema);

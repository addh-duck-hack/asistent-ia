import { Schema, model, type InferSchemaType } from "mongoose";

const messageSchema = new Schema(
  {
    role: { type: String, enum: ["user", "assistant"], required: true },
    // Texto en Markdown; las respuestas citan sesiones como [[sesion:<id>]].
    content: { type: String, required: true },
    citations: [{ type: Schema.Types.ObjectId, ref: "Session" }],
    model: String,
    toolCalls: Number,
    usage: { inputTokens: Number, outputTokens: Number, costUsd: Number },
  },
  { _id: true, timestamps: { createdAt: true, updatedAt: false } },
);

// Conversación de "Preguntar" sobre el historial. El alcance (proyecto o
// persona) es opcional; sin alcance, Claude busca en todo.
const conversationSchema = new Schema(
  {
    title: { type: String, required: true },
    projectId: { type: Schema.Types.ObjectId, ref: "Project" },
    personId: { type: Schema.Types.ObjectId, ref: "Person" },
    messages: [messageSchema],
    costUsd: { type: Number, default: 0 },
  },
  { timestamps: true },
);

conversationSchema.index({ updatedAt: -1 });

export type Conversation = InferSchemaType<typeof conversationSchema>;
export const ConversationModel = model("Conversation", conversationSchema);

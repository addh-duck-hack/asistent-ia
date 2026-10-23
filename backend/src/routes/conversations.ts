import { Router } from "express";
import { Types } from "mongoose";
import { z } from "zod";
import { answerQuestion } from "../llm/ask.js";
import { ConversationModel, SessionModel } from "../models/index.js";

export const conversationsRouter = Router();

const ObjectId = z.string().regex(/^[a-f\d]{24}$/i, "id inválido");
const Question = z.string().trim().min(1).max(2000);

// Sesiones citadas, para que la app muestre título y fecha y las abra.
async function withSessions<T extends { messages: { citations?: Types.ObjectId[] | null }[] }>(conversation: T) {
  const ids = [...new Set(conversation.messages.flatMap((m) => (m.citations ?? []).map(String)))];
  const sessions = await SessionModel.find({ _id: { $in: ids } }).select({ title: 1, date: 1, projectId: 1 }).lean();
  return { ...conversation, sessions };
}

async function ask(conversation: InstanceType<typeof ConversationModel>, question: string) {
  const out = await answerQuestion({
    question,
    history: conversation.messages.map((m) => ({ role: m.role as "user" | "assistant", content: m.content })),
    scope: {
      projectId: conversation.projectId ? String(conversation.projectId) : undefined,
      personId: conversation.personId ? String(conversation.personId) : undefined,
    },
  });
  // Solo se guardan citas a sesiones que existen (Claude podría equivocarse de id).
  const existing = await SessionModel.find({ _id: { $in: out.citations } }).select({ _id: 1 }).lean();
  conversation.messages.push({ role: "user", content: question });
  conversation.messages.push({
    role: "assistant",
    content: out.answer,
    citations: existing.map((s) => s._id),
    model: out.model,
    toolCalls: out.toolCalls,
    usage: out.usage,
  });
  conversation.costUsd = (conversation.costUsd ?? 0) + (out.usage.costUsd ?? 0);
  await conversation.save();
  return withSessions(conversation.toObject());
}

conversationsRouter.get("/", async (_req, res) => {
  const list = await ConversationModel.find()
    .select({ title: 1, projectId: 1, personId: 1, costUsd: 1, updatedAt: 1, createdAt: 1 })
    .sort({ updatedAt: -1 })
    .limit(50)
    .lean();
  res.json(list);
});

conversationsRouter.get("/:id", async (req, res) => {
  const c = await ConversationModel.findById(ObjectId.parse(req.params.id)).lean();
  if (!c) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(await withSessions(c));
});

// Nueva conversación con su primera pregunta (llamada inmediata a Claude).
conversationsRouter.post("/", async (req, res) => {
  const body = z
    .object({ question: Question, projectId: ObjectId.optional(), personId: ObjectId.optional() })
    .parse(req.body ?? {});
  const conversation = new ConversationModel({
    title: body.question.length > 80 ? `${body.question.slice(0, 77)}…` : body.question,
    projectId: body.projectId,
    personId: body.personId,
    messages: [],
  });
  res.status(201).json(await ask(conversation, body.question));
});

// Pregunta de seguimiento.
conversationsRouter.post("/:id/messages", async (req, res) => {
  const { question } = z.object({ question: Question }).parse(req.body ?? {});
  const conversation = await ConversationModel.findById(ObjectId.parse(req.params.id));
  if (!conversation) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(await ask(conversation, question));
});

conversationsRouter.delete("/:id", async (req, res) => {
  const { deletedCount } = await ConversationModel.deleteOne({ _id: ObjectId.parse(req.params.id) });
  res.status(deletedCount ? 200 : 404).json({ deleted: deletedCount });
});

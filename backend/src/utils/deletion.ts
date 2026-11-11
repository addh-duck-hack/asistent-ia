import type { Types } from "mongoose";
import {
  ActionItemModel,
  AnalysisModel,
  DigestModel,
  OneOnOneModel,
  PersonModel,
  ProjectModel,
  SessionModel,
  TranscriptModel,
} from "../models/index.js";

type Id = string | Types.ObjectId;

/**
 * Borra sesiones con su transcripción, sus análisis y los pendientes que
 * nacieron en ellas. Los cambios de estado que provocaron en pendientes de
 * otras sesiones se conservan (forman parte del historial de esos pendientes).
 */
export async function deleteSessions(sessionIds: Id[]) {
  if (sessionIds.length === 0) return { sessions: 0, actionItems: 0 };
  const [, , items, sessions] = await Promise.all([
    TranscriptModel.deleteMany({ sessionId: { $in: sessionIds } }),
    AnalysisModel.deleteMany({ sessionId: { $in: sessionIds } }),
    ActionItemModel.deleteMany({ sessionId: { $in: sessionIds } }),
    SessionModel.deleteMany({ _id: { $in: sessionIds } }),
  ]);
  return { sessions: sessions.deletedCount, actionItems: items.deletedCount };
}

/** Borra un proyecto con todas sus sesiones, pendientes y resúmenes. Las personas se conservan. */
export async function deleteProject(projectId: Id) {
  const sessionIds = (await SessionModel.find({ projectId }).select({ _id: 1 }).lean()).map((s) => s._id);
  const fromSessions = await deleteSessions(sessionIds);
  const [manualItems, digests, project] = await Promise.all([
    ActionItemModel.deleteMany({ projectId }), // tareas manuales del proyecto
    DigestModel.deleteMany({ projectId }),
    ProjectModel.deleteOne({ _id: projectId }),
  ]);
  return {
    project: project.deletedCount,
    sessions: fromSessions.sessions,
    actionItems: fromSessions.actionItems + manualItems.deletedCount,
    digests: digests.deletedCount,
  };
}

/**
 * Borra a una persona y sus preparaciones de 1:1, y la quita de los proyectos.
 * Sus pendientes se conservan con el nombre escrito, pero sin ligarse a nadie.
 */
export async function deletePerson(personId: Id) {
  const [items, , oneOnOnes, person] = await Promise.all([
    ActionItemModel.updateMany({ ownerId: personId }, { $unset: { ownerId: 1 } }),
    ProjectModel.updateMany({ members: personId }, { $pull: { members: personId } }),
    OneOnOneModel.deleteMany({ personId }),
    PersonModel.deleteOne({ _id: personId }),
  ]);
  return { person: person.deletedCount, unlinkedItems: items.modifiedCount, oneOnOnes: oneOnOnes.deletedCount };
}

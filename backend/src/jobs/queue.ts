import { agenda } from "./agenda.js";

export const ANALYZE_SESSION_JOB = "analyze-session";

export interface AnalyzeSessionJobData {
  sessionId: string;
}

// El API solo encola; el worker define el job y lo procesa.
export async function enqueueAnalysis(sessionId: string): Promise<void> {
  await agenda.ready;
  await agenda.now<AnalyzeSessionJobData>(ANALYZE_SESSION_JOB, { sessionId });
}

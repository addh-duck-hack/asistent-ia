import { Schema, model, type InferSchemaType } from "mongoose";

/**
 * Historial de fallos del análisis: la sesión solo guarda el último error y se
 * borra al re-analizar; aquí queda cada intento para revisarlo después.
 */
const errorLogSchema = new Schema(
  {
    source: { type: String, enum: ["analysis"], default: "analysis" },
    sessionId: { type: Schema.Types.ObjectId, ref: "Session" },
    projectId: { type: Schema.Types.ObjectId, ref: "Project" },
    // Copia del título: el log se entiende aunque la sesión se borre.
    title: { type: String },
    message: { type: String, required: true },
    // El worker reintenta los errores transitorios; false = no se reintentará solo.
    retryable: { type: Boolean, default: true },
    // Se llena cuando un análisis posterior de la misma sesión termina bien.
    resolvedAt: { type: Date },
  },
  { timestamps: true },
);

errorLogSchema.index({ createdAt: -1 });
errorLogSchema.index({ sessionId: 1 });

export type ErrorLog = InferSchemaType<typeof errorLogSchema>;
export const ErrorLogModel = model("ErrorLog", errorLogSchema);

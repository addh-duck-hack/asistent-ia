import { Schema, model, type InferSchemaType } from "mongoose";

// Los datos de RH (sueldo, vacaciones, horas extra, ánimo, notas) llevan
// `select: false`: ninguna consulta normal los trae, así que no pueden acabar
// en el listado del equipo ni en lo que se le manda a Claude. Solo los lee el
// perfil (routes/profile.ts), que los pide explícitamente.
const personSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    email: { type: String, trim: true, lowercase: true },
    role: { type: String, default: "" },
    // Variantes con las que aparece en transcripciones/Teams ("Juan", "JP", ...).
    aliases: [{ type: String, trim: true }],
    // Archivar sin borrar: conserva su historial pero deja de aparecer y de asignarse.
    active: { type: Boolean, default: true },

    // Fechas de calendario (a medianoche UTC).
    birthday: { type: Date },
    startDate: { type: Date },
    level: { type: String, trim: true },
    contractType: { type: String, trim: true },
    skills: [{ type: String, trim: true }],

    notes: { type: String, select: false },
    nextSalaryReview: { type: Date, select: false },
    // Días de vacaciones por año si la empresa da distintos a los de la ley.
    vacationDaysOverride: { type: Number, select: false },
    salaryHistory: {
      select: false,
      type: [
        {
          amount: { type: Number, required: true },
          currency: { type: String, default: "MXN" },
          period: { type: String, enum: ["monthly", "biweekly", "weekly", "hourly", "yearly"], default: "monthly" },
          effectiveDate: { type: Date, required: true },
          note: String,
        },
      ],
    },
    vacations: {
      select: false,
      type: [{ startDate: { type: Date, required: true }, endDate: { type: Date, required: true }, days: { type: Number, required: true }, note: String }],
    },
    overtime: {
      select: false,
      type: [
        {
          date: { type: Date, required: true },
          hours: { type: Number, required: true },
          reason: String,
          projectId: { type: Schema.Types.ObjectId, ref: "Project" },
          status: { type: String, enum: ["pending", "paid", "compensated"], default: "pending" },
        },
      ],
    },
    moods: {
      select: false,
      type: [
        {
          date: { type: Date, required: true },
          level: { type: Number, min: 1, max: 5, required: true },
          note: String,
          // Sesión de la que salió, si se confirmó una sugerencia de Claude.
          sessionId: { type: Schema.Types.ObjectId, ref: "Session" },
        },
      ],
    },
    // Lo que Claude notó en una sesión; el líder lo confirma o lo descarta.
    moodSuggestions: {
      select: false,
      type: [
        {
          sessionId: { type: Schema.Types.ObjectId, ref: "Session", required: true },
          date: { type: Date, required: true },
          level: { type: Number, min: 1, max: 5, required: true },
          evidence: String,
        },
      ],
    },
  },
  { timestamps: true },
);

export const PROFILE_FIELDS = "+notes +nextSalaryReview +vacationDaysOverride +salaryHistory +vacations +overtime +moods +moodSuggestions";

export type Person = InferSchemaType<typeof personSchema>;
export const PersonModel = model("Person", personSchema);

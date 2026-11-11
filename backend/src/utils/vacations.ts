// Vacaciones según la Ley Federal del Trabajo (art. 76, reforma de 2023):
// 12 días al cumplir el primer año, +2 por año hasta 20 (año 5); del año 6 en
// adelante, +2 por cada 5 años (22 de 6 a 10, 24 de 11 a 15…).
export function lftVacationDays(completedYears: number): number {
  if (completedYears < 1) return 0;
  if (completedYears <= 5) return 10 + completedYears * 2;
  return 20 + Math.ceil((completedYears - 5) / 5) * 2;
}

function addYears(date: Date, years: number): Date {
  const d = new Date(date);
  d.setUTCFullYear(d.getUTCFullYear() + years);
  return d;
}

export function completedYears(startDate: Date, now: Date): number {
  let years = now.getUTCFullYear() - startDate.getUTCFullYear();
  if (addYears(startDate, years) > now) years--;
  return Math.max(0, years);
}

export interface VacationSummary {
  yearsOfService: number;
  /** Periodo vigente: del último aniversario al siguiente. */
  periodStart: Date;
  periodEnd: Date;
  total: number;
  taken: number;
  remaining: number;
  /** Días que le tocarán al cumplir el siguiente año. */
  nextTotal: number;
  source: "law" | "override";
}

/**
 * Días del periodo vigente. Los días se ganan al cumplir cada año y se
 * cuentan como disfrutados los periodos que empiezan dentro del año vigente.
 * No arrastra saldos de años anteriores: para eso está el ajuste manual.
 */
export function vacationSummary(
  startDate: Date,
  vacations: { startDate: Date; days: number }[],
  override: number | null | undefined,
  now = new Date(),
): VacationSummary {
  const years = completedYears(startDate, now);
  const periodStart = addYears(startDate, years);
  const periodEnd = addYears(startDate, years + 1);
  const total = override ?? lftVacationDays(years);
  const taken = vacations.filter((v) => v.startDate >= periodStart && v.startDate < periodEnd).reduce((sum, v) => sum + v.days, 0);
  return {
    yearsOfService: years,
    periodStart,
    periodEnd,
    total,
    taken,
    remaining: total - taken,
    nextTotal: override ?? lftVacationDays(years + 1),
    source: override == null ? "law" : "override",
  };
}

// src/validation.ts
// Phase 1 SatChart validation (2012–2024)

export type DistrictKey =
  | "naknek-kvichak"
  | "egegik"
  | "ugashik"
  | "nushagak"
  | "togiak";

export type RiverKey =
  | "kvichak"
  | "naknek"
  | "alagnak"
  | "egegik"
  | "ugashik"
  | "wood"
  | "igushik"
  | "togiak"
  | "nushagak";

export type EscapementMethod = "tower" | "sonar" | "aerial";
export type DriftScope = "district" | "section" | "mixed" | "unknown";
export type TogiakReason = "fixed_date" | "escapement_waiver";
export type Severity = "error" | "warn";

export interface ValidationIssue {
  severity: Severity;
  code: string;
  message: string;
  path?: string;
}

/* ------------------ Utilities ------------------ */

function isYYYYMMDD(s: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(s);
}

function isNum(n: unknown): n is number {
  return typeof n === "number" && Number.isFinite(n);
}

function approxEqual(a: number, b: number, eps = 1e-6): boolean {
  return Math.abs(a - b) <= eps;
}

/* ------------------ Data Models ------------------ */

export interface DailyDistrictOps {
  year: number;
  date: string;
  districtKey: DistrictKey;

  driftOpenHours: number;
  driftOpenHoursBySection?: Record<string, number>;
  driftOpenHoursScope?: DriftScope;

  setOpenHours?: number;

  // Permits/boats may be unknown on some days (e.g. post-registration cutoff)
  driftPermits?: number | null;
  dualPermits?: number | null;
  driftBoats?: number | null;

  // Optional deliveries (you added this in loaders)
  deliveries?: {
    drift?: number | null;
    set?: number | null;
    source?: string;
  };

  catch: {
    sockeye?: number | null;
    chinook?: number | null;
    chum?: number | null;
    pink?: number | null;
    coho?: number | null;
    total: number | null; // you use this as daily sockeye in ops CSV
  };

  notes?: string[];
}

export interface DailyRiverEscapement {
  year: number;
  date: string;
  riverKey: RiverKey;

  method: EscapementMethod;
  isOperational: boolean;

  dailyEscapement: number | null;
  cumulativeEscapement?: number | null;
}

export interface YearDistrictForecastOutcome {
  year: number;
  districtKey: DistrictKey;

  forecast: {
    inshoreRun: number;
    harvest: number;
    escapementGoal?: {
      min?: number;
      max?: number;
    };
  };

  observed: {
    inshoreRun: number;
    harvest: number;
    escapement: number;
  };

  units: "millions_of_fish";
  notes?: string[];
}

export interface YearMeta {
  year: number;
  togiakOutsiderOpenDate: string;
  togiakOutsiderOpenReason: TogiakReason;
  allocationEndDate?: string;
  notes?: string[];
}

/* ------------------ Validators ------------------ */

export function validateDailyDistrictOps(d: DailyDistrictOps): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (d.year < 2012 || d.year > 2024) {
    issues.push({ severity: "error", code: "year_range", message: "Year must be 2012–2024" });
  }

  if (!isYYYYMMDD(d.date)) {
    issues.push({ severity: "error", code: "date_format", message: "Invalid date format", path: "date" });
  }

  if (!isNum(d.driftOpenHours) || d.driftOpenHours < 0) {
    issues.push({ severity: "error", code: "drift_hours", message: "driftOpenHours must be >= 0" });
  }

  // Permits may be unknown; only validate when present
  if (d.driftPermits != null) {
    if (!isNum(d.driftPermits) || d.driftPermits < 0) {
      issues.push({ severity: "error", code: "drift_permits", message: "driftPermits must be >= 0" });
    }
  }

  if (d.dualPermits != null) {
    if (!isNum(d.dualPermits) || d.dualPermits < 0) {
      issues.push({ severity: "error", code: "dual_permits", message: "dualPermits must be >= 0" });
    }
  }

  if (isNum(d.driftPermits) && isNum(d.dualPermits) && d.dualPermits > d.driftPermits) {
    issues.push({ severity: "error", code: "dual_gt_total", message: "dualPermits > driftPermits" });
  }

  // Only enforce boats relationship when all three are present
  if (isNum(d.driftPermits) && isNum(d.dualPermits) && isNum(d.driftBoats)) {
    const computed = d.driftPermits - d.dualPermits;
    if (!approxEqual(d.driftBoats, computed)) {
      issues.push({
        severity: "error",
        code: "boats_mismatch",
        message: `driftBoats != driftPermits - dualPermits (${computed})`,
      });
    }
  }

  // Warn only when boats & permits are known
  if (
    d.driftOpenHours > 0 &&
    isNum(d.driftPermits) && d.driftPermits > 0 &&
    isNum(d.driftBoats) && d.driftBoats <= 0
  ) {
    issues.push({
      severity: "warn",
      code: "open_no_boats",
      message: "Open drift with zero boats (no participation / no registrations)",
    });
  }

  if (d.catch.total !== null && d.catch.total < 0) {
    issues.push({ severity: "error", code: "negative_catch", message: "Negative catch total" });
  }

  // If closed to BOTH gears, total should be 0; warn if not (delivery attribution edge cases).
  const setHours = d.setOpenHours ?? 0;
  const hasHoursUnknownNote = (d.notes ?? []).includes("hours_not_reported_in_table");

  if (
    d.driftOpenHours === 0 &&
    setHours === 0 &&
    d.catch.total !== 0 &&
    d.catch.total !== null &&
    !hasHoursUnknownNote
  ) {
    issues.push({
      severity: "warn",
      code: "catch_when_closed",
      message: "Catch recorded while closed (verify deliveries / district attribution)",
    });
  }

  // Section sum check only when provided
  if (d.driftOpenHoursBySection) {
    const sum = Object.values(d.driftOpenHoursBySection).reduce((a, b) => a + b, 0);
    if (!approxEqual(sum, d.driftOpenHours)) {
      issues.push({
        severity: "error",
        code: "section_hours_sum",
        message: "Section hours do not sum to driftOpenHours",
      });
    }
  }

  return issues;
}

export function validateDailyRiverEscapement(r: DailyRiverEscapement): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (!isYYYYMMDD(r.date)) {
    issues.push({ severity: "error", code: "date_format", message: "Invalid date", path: "date" });
  }

  if (!r.isOperational && r.dailyEscapement !== null) {
    issues.push({ severity: "error", code: "nd_not_null", message: "Non-operational day has escapement" });
  }

  if (r.isOperational && (!isNum(r.dailyEscapement) || r.dailyEscapement < 0)) {
    issues.push({ severity: "error", code: "bad_escapement", message: "Invalid daily escapement" });
  }

  return issues;
}

export function validateYearDistrictForecastOutcome(y: YearDistrictForecastOutcome): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (y.units !== "millions_of_fish") {
    issues.push({ severity: "error", code: "bad_units", message: "Units must be millions_of_fish" });
  }

  const nums = [
    y.forecast.inshoreRun,
    y.forecast.harvest,
    y.observed.inshoreRun,
    y.observed.harvest,
    y.observed.escapement,
  ];

  if (nums.some((n) => !isNum(n) || n < 0)) {
    issues.push({ severity: "error", code: "negative_number", message: "Negative or invalid forecast/observed value" });
  }

  const g = y.forecast.escapementGoal;
  if (g?.min !== undefined && g?.max !== undefined && g.min > g.max) {
    issues.push({ severity: "error", code: "goal_range", message: "Escapement goal min > max" });
  }

  return issues;
}

export function validateYearMeta(m: YearMeta): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  if (!isYYYYMMDD(m.togiakOutsiderOpenDate)) {
    issues.push({ severity: "error", code: "bad_togiak_date", message: "Invalid Togiak open date" });
  }

  return issues;
}
// src/batchValidation.ts
import {
  DailyDistrictOps,
  DailyRiverEscapement,
  YearDistrictForecastOutcome,
  YearMeta,
  ValidationIssue,
  validateDailyDistrictOps,
  validateDailyRiverEscapement,
  validateYearDistrictForecastOutcome,
  validateYearMeta,
} from "./validation";

export interface YearBatch {
  ops: DailyDistrictOps[];
  rivers: DailyRiverEscapement[];
  forecasts: YearDistrictForecastOutcome[];
  meta: YearMeta;
}

function key3(a: string | number, b: string | number, c: string | number) {
  return `${a}__${b}__${c}`;
}
function key2(a: string | number, b: string | number) {
  return `${a}__${b}`;
}

export function validateYearBatch(batch: YearBatch): ValidationIssue[] {
  const issues: ValidationIssue[] = [];

  // 1) Single-record validation
  for (const d of batch.ops) issues.push(...validateDailyDistrictOps(d));
  for (const r of batch.rivers) issues.push(...validateDailyRiverEscapement(r));
  for (const f of batch.forecasts) issues.push(...validateYearDistrictForecastOutcome(f));
  issues.push(...validateYearMeta(batch.meta));

  // 2) Duplicate key checks
  const opsSeen = new Set<string>();
  for (const d of batch.ops) {
    const k = key3(d.year, d.date, d.districtKey);
    if (opsSeen.has(k)) {
      issues.push({ severity: "error", code: "dup_daily_ops", message: `Duplicate dailyDistrictOps: ${k}` });
    }
    opsSeen.add(k);
  }

  const riversSeen = new Set<string>();
  for (const r of batch.rivers) {
    const k = key3(r.year, r.date, r.riverKey);
    if (riversSeen.has(k)) {
      issues.push({ severity: "error", code: "dup_river", message: `Duplicate dailyRiverEscapement: ${k}` });
    }
    riversSeen.add(k);
  }

  const fcSeen = new Set<string>();
  for (const f of batch.forecasts) {
    const k = key2(f.year, f.districtKey);
    if (fcSeen.has(k)) {
      issues.push({ severity: "error", code: "dup_forecast", message: `Duplicate yearDistrictForecastOutcome: ${k}` });
    }
    fcSeen.add(k);
  }

  // 3) Escapement cumulative monotonic check (if cumulativeEscapement present)
  const byRiver: Record<string, DailyRiverEscapement[]> = {};
  for (const r of batch.rivers) (byRiver[r.riverKey] ??= []).push(r);

  for (const riverKey of Object.keys(byRiver)) {
    const rows = byRiver[riverKey].slice().sort((a, b) => a.date.localeCompare(b.date));

    let lastCum: number | null = null;

    for (const row of rows) {
      const cum = row.cumulativeEscapement ?? null;

      if (cum === null) continue;
      if (typeof cum !== "number") continue;

      if (lastCum !== null && cum < lastCum) {
        issues.push({
          severity: "error",
          code: "cum_decrease",
          message: `${riverKey} cumulative decreased ${lastCum} -> ${cum} on ${row.date}`,
          path: `dailyRiverEscapement:${riverKey}:${row.date}`,
        });
      }
      lastCum = cum;
    }
  }

  // 4) MOI window district coverage check (June 1 – July 17)
  const year = batch.meta.year;
  const windowStart = `${year}-06-12`;
const windowEnd = (year === 2023 || year === 2024) ? `${year}-08-03` : `${year}-07-17`;

  const districtsInWindow = new Set<string>();
  for (const d of batch.ops) {
    if (d.date >= windowStart && d.date <= windowEnd) districtsInWindow.add(d.districtKey);
  }

  const requiredDistricts = ["naknek-kvichak", "egegik", "ugashik", "nushagak", "togiak"];
  for (const dk of requiredDistricts) {
    if (!districtsInWindow.has(dk)) {
      issues.push({
        severity: "error",
        code: "missing_district_window",
        message: `Missing ${dk} in dailyDistrictOps within ${windowStart}..${windowEnd}`,
      });
    }
  }

  return issues;
}

export function assertNoErrors(issues: ValidationIssue[]): void {
  const errs = issues.filter((i) => i.severity === "error");
  if (errs.length === 0) return;

  const msg = errs
    .map((e) => `- [${e.code}] ${e.message}${e.path ? ` (${e.path})` : ""}`)
    .join("\n");

  throw new Error(`Validation failed:\n${msg}`);
}
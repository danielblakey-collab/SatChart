import { YearBatch } from "../batchValidation";
import fs from "fs";
import path from "path";
import Papa from "papaparse";

function readCsv(absPath: string): Record<string, any>[] {
  const raw = fs.readFileSync(absPath, "utf8");
  const parsed = Papa.parse<Record<string, any>>(raw, {
    header: true,
    skipEmptyLines: true,
  });
  if (parsed.errors?.length) {
    const msg = parsed.errors.map(e => `${e.row}: ${e.message}`).join("; ");
    throw new Error(`CSV parse error for ${absPath}: ${msg}`);
  }
  return (parsed.data || []).filter(Boolean) as Record<string, any>[];
}

function toNum(v: any): number | null {
  if (v === undefined || v === null) return null;
  const s = String(v).trim();
  if (s === "" || s === "-" || s === "–" || s === "ND" || s === "nd") return null;
  const cleaned = s.replace(/,/g, "");
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function toBool(v: any): boolean {
  const s = String(v ?? "").trim().toLowerCase();
  return s === "true" || s === "1" || s === "yes";
}

function splitPipe(v: any): string[] {
  const s = String(v ?? "").trim();
  if (!s) return [];
  return s.split("|").map(x => x.trim()).filter(Boolean);
}

export async function load2024(): Promise<YearBatch> {
  const year = 2024;

  const opsPath = path.resolve(process.cwd(), "src/data/2024/ops_2024.csv");
  const riversPath = path.resolve(process.cwd(), "src/data/2024/rivers_2024.csv");
  const regPath = path.resolve(process.cwd(), "src/data/2024/registration_2024.csv");

  const opsCsv = fs.existsSync(opsPath) ? readCsv(opsPath) : [];
  const riversCsv = fs.existsSync(riversPath) ? readCsv(riversPath) : [];
  const regCsv = fs.existsSync(regPath) ? readCsv(regPath) : [];

  // Registration lookup: `${date}__${districtKey}` -> permits/duals/boats
  const regByKey = new Map<
    string,
    { driftPermits: number | null; dualPermits: number | null; driftBoats: number | null; flags: string[]; notes: string[] }
  >();

  for (const r of regCsv) {
    const date = String(r.date ?? "").trim();
    const districtKey = String(r.districtKey ?? "").trim();
    if (!date || !districtKey) continue;

    regByKey.set(`${date}__${districtKey}`, {
      driftPermits: toNum(r.driftPermits),
      dualPermits: toNum(r.dualPermits),
      driftBoats: toNum(r.driftBoats),
      flags: splitPipe(r.flags),
      notes: splitPipe(r.notes),
    });
  }

  // Build ops rows from catch tables (ops CSV)
  const opsBase = opsCsv.map(r => {
    const date = String(r.date ?? "").trim();
    const districtKey = String(r.districtKey ?? "").trim();
    if (!date || !districtKey) return null;

    const reg = regByKey.get(`${date}__${districtKey}`);
    const baseFlags = splitPipe(r.flags);
    const baseNotes = splitPipe(r.notes);

    const driftOpenHours = toNum(r.driftOpenHours) ?? 0;
    const setOpenHours = toNum(r.setOpenHours) ?? 0;

    return {
      year,
      date,
      districtKey: districtKey as any,

      driftOpenHours,
      setOpenHours,

      // Fill registration if present (Table 10 window); otherwise null
      driftPermits: reg?.driftPermits ?? null,
      dualPermits: reg?.dualPermits ?? null,
      driftBoats: reg?.driftBoats ?? null,

      // ✅ CRITICAL: write deliveries map so computeEstimatedRegistration can calibrate
      deliveries: {
        drift: toNum(r.driftDeliveries),
        set: toNum(r.setDeliveries),
        source: "FMR Table (district catch table)",
      },

      // You confirmed catch.total is DAILY SOCKEYE
      catch: {
        total: toNum(r.sockeyeDaily),
      },

      flags: [...baseFlags, ...(reg?.flags ?? [])],
      notes: [...baseNotes, ...(reg?.notes ?? [])],
    };
  }).filter(Boolean) as any[];

  // Also emit “registration-only” ops rows for days where reg exists but ops row is missing
  // (so driftBoats/permits exist even on days not present in the catch table)
  const opsKeys = new Set<string>(opsBase.map(o => `${o.date}__${o.districtKey}`));

  const regOnlyOps: any[] = [];
  for (const [k, v] of regByKey.entries()) {
    if (opsKeys.has(k)) continue;
    const [date, districtKey] = k.split("__");

    regOnlyOps.push({
      year,
      date,
      districtKey: districtKey as any,

      driftOpenHours: 0,
      setOpenHours: 0,

      driftPermits: v.driftPermits ?? null,
      dualPermits: v.dualPermits ?? null,
      driftBoats: v.driftBoats ?? null,

      deliveries: { drift: null, set: null, source: "registration_only" },

      catch: { total: null },

      flags: [...(v.flags ?? []), "registration_only_row"],
      notes: v.notes ?? [],
    });
  }

  const ops = [...opsBase, ...regOnlyOps];

  // Rivers (tower + sonar)
  const rivers = riversCsv.map(r => ({
    year,
    date: String(r.date ?? "").trim(),
    riverKey: String(r.riverKey ?? "").trim() as any,

    method: String(r.method ?? "tower").trim().toLowerCase() === "sonar" ? "sonar" : "tower",
    isOperational: toBool(r.isOperational),

    dailyEscapement: toNum(r.dailyEscapement),
    cumulativeEscapement: toNum(r.cumulativeEscapement),

    flags: splitPipe(r.flags),
    notes: splitPipe(r.notes),
  }));

  return {
    meta: {
      year,
      allocationEndDate: "2024-08-03",
      // keep your existing values or adjust later
      togiakOutsiderOpenDate: "2024-07-27",
      togiakOutsiderOpenReason: "escapement_waiver",
    },
    forecasts: [],
    ops: ops as any,
    rivers: rivers as any,
  };
}

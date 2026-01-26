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
  if (s === "" || s === "-" || s === "–") return null;
  const cleaned = s.replace(/,/g, "");
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function toBool(v: any): boolean {
  const s = String(v).trim().toLowerCase();
  return s === "true" || s === "1" || s === "yes";
}

function splitPipe(v: any): string[] {
  const s = String(v ?? "").trim();
  if (!s) return [];
  return s.split("|").map(x => x.trim()).filter(Boolean);
}

export async function load2023(): Promise<YearBatch> {
  const year = 2023;

  const opsPath = path.resolve(process.cwd(), "src/data/2023/ops_2023.csv");
  const riversPath = path.resolve(process.cwd(), "src/data/2023/rivers_2023.csv");
  const regPath = path.resolve(process.cwd(), "src/data/2023/registration_2023.csv");

  const opsCsv = fs.existsSync(opsPath) ? readCsv(opsPath) : [];
  const riversCsv = fs.existsSync(riversPath) ? readCsv(riversPath) : [];
  const regCsv = fs.existsSync(regPath) ? readCsv(regPath) : [];

  // Build registration lookup: `${date}__${districtKey}` -> { permits/duals/boats }
  const regByKey = new Map<
    string,
    {
      driftPermits: number | null;
      dualPermits: number | null;
      driftBoats: number | null;
      flags: string[];
      notes: string[];
    }
  >();

  for (const r of regCsv) {
    const date = String(r.date).trim();
    const districtKey = String(r.districtKey).trim();
    if (!date || !districtKey) continue;

    regByKey.set(`${date}__${districtKey}`, {
      driftPermits: toNum(r.driftPermits),
      dualPermits: toNum(r.dualPermits),
      driftBoats: toNum(r.driftBoats),
      flags: splitPipe(r.flags),
      notes: splitPipe(r.notes),
    });
  }

  // Build ops rows and merge registration where available.
  const opsBase = opsCsv.map(r => {
    const date = String(r.date).trim();
    const districtKey = String(r.districtKey).trim();

    const reg = regByKey.get(`${date}__${districtKey}`);

    const baseFlags = splitPipe(r.flags);
    const baseNotes = splitPipe(r.notes);

    return {
      year,
      date,
      districtKey: districtKey as any,

      driftOpenHours: toNum(r.driftOpenHours) ?? 0,
      setOpenHours: toNum(r.setOpenHours) ?? 0,

      // Prefer explicit values in ops CSV; otherwise fill from registration CSV
      driftPermits: toNum(r.driftPermits) ?? reg?.driftPermits ?? null,
      dualPermits: toNum(r.dualPermits) ?? reg?.dualPermits ?? null,
      driftBoats: toNum(r.driftBoats) ?? reg?.driftBoats ?? null,

      deliveries: {
        drift: toNum(r.driftDeliveries),
        set: toNum(r.setDeliveries),
        source: "FMR Table (district catch table)",
      },

      catch: {
        // You confirmed catch.total is DAILY SOCKEYE
        total: toNum(r.sockeyeDaily),
      },

      flags: [...baseFlags, ...(reg?.flags ?? [])],
      notes: [...baseNotes, ...(reg?.notes ?? [])],
    };
  });

  // --- Add registration-only ops rows so EVERY registration day exists ---
  const opsByKey = new Map<string, any>();
  for (const o of opsBase) {
    opsByKey.set(`${o.date}__${o.districtKey}`, o);
  }

  for (const [k, reg] of regByKey.entries()) {
    const existing = opsByKey.get(k);

    if (existing) {
      // If row exists but permits missing, fill them.
      if (existing.driftPermits == null) existing.driftPermits = reg.driftPermits ?? null;
      if (existing.dualPermits == null) existing.dualPermits = reg.dualPermits ?? null;
      if (existing.driftBoats == null) existing.driftBoats = reg.driftBoats ?? null;

      existing.flags = [...(existing.flags ?? []), ...(reg.flags ?? [])];
      existing.notes = [...(existing.notes ?? []), ...(reg.notes ?? [])];
      continue;
    }

    const [date, districtKey] = k.split("__");

    opsByKey.set(k, {
      year,
      date,
      districtKey: districtKey as any,

      driftOpenHours: 0,
      setOpenHours: 0,

      driftPermits: reg.driftPermits ?? null,
      dualPermits: reg.dualPermits ?? null,
      driftBoats: reg.driftBoats ?? null,

      deliveries: {
        drift: null,
        set: null,
        source: "registration_only",
      },

      catch: {
        total: 0,
      },

      flags: ["registration_only_row", ...(reg.flags ?? [])],
      notes: [...(reg.notes ?? [])],
    });
  }

  const ops = Array.from(opsByKey.values()).sort((a: any, b: any) => {
    const c = String(a.date).localeCompare(String(b.date));
    return c !== 0 ? c : String(a.districtKey).localeCompare(String(b.districtKey));
  });

  const rivers = riversCsv.map(r => ({
    year,
    date: String(r.date).trim(),
    riverKey: String(r.riverKey).trim() as any,

    method: (String(r.method || "tower").trim().toLowerCase() === "sonar" ? "sonar" : "tower"),
    isOperational: toBool(r.isOperational),

    dailyEscapement: toNum(r.dailyEscapement),
    cumulativeEscapement: toNum(r.cumulativeEscapement),

    flags: splitPipe(r.flags),
    notes: splitPipe(r.notes),
  }));

  return {
    meta: {
      year,
      allocationEndDate: "2023-08-03",
      // Required by YearMeta (confirm later from report narrative)
      togiakOutsiderOpenDate: "2023-07-27",
      togiakOutsiderOpenReason: "escapement_waiver",
    },
    forecasts: [],
    ops: ops as any,
    rivers: rivers as any,
  };
}
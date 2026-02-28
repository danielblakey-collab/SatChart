import { YearBatch } from "../batchValidation";
import fs from "fs";
import path from "path";
import Papa from "papaparse";

function readCsv(absPath: string): Record<string, any>[] {
  const raw = fs.readFileSync(absPath, "utf8");
  const parsed = Papa.parse<Record<string, any>>(raw, { header: true, skipEmptyLines: true });
  if (parsed.errors?.length) {
    const msg = parsed.errors.map(e => `${e.row}: ${e.message}`).join("; ");
    throw new Error(`CSV parse error for ${absPath}: ${msg}`);
  }
  return (parsed.data || []).filter(Boolean) as Record<string, any>[];
}

function toNum(v: any): number | null {
  if (v === undefined || v === null) return null;
  const s = String(v).trim();
  if (s === "" || s === "-" || s === "–" || s.toUpperCase() === "ND") return null;
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

export async function load2020(): Promise<YearBatch> {
  const year = 2020;

  const opsPath = path.resolve(process.cwd(), "src/data/2020/ops_2020.csv");
  const riversPath = path.resolve(process.cwd(), "src/data/2020/rivers_2020.csv");
  const regPath = path.resolve(process.cwd(), "src/data/2020/registration_2020.csv");

  const opsCsv = fs.existsSync(opsPath) ? readCsv(opsPath) : [];
  const riversCsv = fs.existsSync(riversPath) ? readCsv(riversPath) : [];
  const regCsv = fs.existsSync(regPath) ? readCsv(regPath) : [];

  // registration lookup: `${date}__${districtKey}`
  const regByKey = new Map<
    string,
    { driftPermits: number | null; dualPermits: number | null; driftBoats: number | null; flags: string[]; notes: string[] }
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

  const ops = opsCsv.map(r => {
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

      driftPermits: toNum(r.driftPermits) ?? reg?.driftPermits ?? null,
      dualPermits: toNum(r.dualPermits) ?? reg?.dualPermits ?? null,
      driftBoats: toNum(r.driftBoats) ?? reg?.driftBoats ?? null,

      deliveries: {
        drift: toNum(r.driftDeliveries) ?? 0,
        set: toNum(r.setDeliveries) ?? 0,
        source: "FMR Table (district catch table)",
      },

      catch: {
        // DAILY combined sockeye (drift+set); you’ll allocate later
        total: toNum(r.sockeyeDaily) ?? 0,
      },

      flags: [...baseFlags, ...(reg?.flags ?? [])],
      notes: [...baseNotes, ...(reg?.notes ?? [])],
    };
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
      allocationEndDate: "2020-08-03",
      // confirm later from narrative
      togiakOutsiderOpenDate: "2020-07-27",
      togiakOutsiderOpenReason: "escapement_waiver",
    },
    forecasts: [],
    ops: ops as any,
    rivers: rivers as any,
  };
}
import fs from "fs";
import path from "path";
import Papa from "papaparse";

export type DistrictKey = "naknek-kvichak" | "egegik" | "ugashik" | "nushagak" | "togiak";

type Row = {
  year: string;
  naknek_kvichak_drift: string;
  egegik_drift: string;
  ugashik_drift: string;
  nushagak_drift: string;
  togiak_drift: string;
};

let cache: Map<number, Record<DistrictKey, number | null>> | null = null;

function pctToFrac(v: any): number | null {
  const s = String(v ?? "").trim();
  if (!s || s.toUpperCase() === "ND") return null;
  const n = Number(s.replace(/,/g, ""));
  return Number.isFinite(n) ? n / 100 : null;
}

function load(): Map<number, Record<DistrictKey, number | null>> {
  if (cache) return cache;

  const file = path.resolve(process.cwd(), "src/data/alloc/appendix_a9_drift_share_2010_2024.csv");
  const raw = fs.readFileSync(file, "utf8");

  const parsed = Papa.parse<Row>(raw, { header: true, skipEmptyLines: true });
  if (parsed.errors?.length) {
    const msg = parsed.errors.map(e => `${e.row}: ${e.message}`).join("; ");
    throw new Error(`Appendix A9 drift-share CSV parse error: ${msg}`);
  }

  const m = new Map<number, Record<DistrictKey, number | null>>();

  for (const r of parsed.data) {
    const y = Number(String(r.year ?? "").trim());
    if (!y) continue;

    m.set(y, {
      "naknek-kvichak": pctToFrac(r.naknek_kvichak_drift),
      "egegik": pctToFrac(r.egegik_drift),
      "ugashik": pctToFrac(r.ugashik_drift),
      "nushagak": pctToFrac(r.nushagak_drift),
      "togiak": pctToFrac(r.togiak_drift),
    });
  }

  cache = m;
  return m;
}

export function getDriftShare(year: number, districtKey: DistrictKey): number | null {
  const row = load().get(year);
  return row ? row[districtKey] : null;
}

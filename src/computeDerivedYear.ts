import { initFirestore } from "./firestore";
import { loadYear } from "./loaders";
import { validateYearBatch, assertNoErrors } from "./batchValidation";

type EscRow = {
  riverKey: string;
  method: "tower" | "sonar" | "aerial";
  isOperational: boolean;
  dailyEscapement: number | null;
  cumulativeEscapement?: number | null;
};

type DerivedRow = {
  year: number;
  date: string;
  districtKey: string;

  driftBoats: number;
  driftOpenHours: number;
  driftBoatHours: number;

  totalHarvest: number | null;

  avgCatchPerDriftBoat: number | null;
  fishPerDriftBoatHour: number | null;

  bestDistrictKey_avgCatchPerDriftBoat: string | null;
  bestValue_avgCatchPerDriftBoat: number | null;
  teleportMOI_avgCatchPerDriftBoat: number | null;

  escapementPrimary: {
    riverKey: string;
    method: "tower" | "sonar" | "aerial";
    daily: number | null;
    cumulative: number | null;
    isOperational: boolean;
  } | null;

  escapementDetails: Array<{
    riverKey: string;
    method: "tower" | "sonar" | "aerial";
    daily: number | null;
    cumulative: number | null;
    isOperational: boolean;
  }>;

  flags: string[];
  updatedAt: string;
};

const DISTRICT_RIVERS: Record<string, { primary: string; details: string[] }> = {
  "naknek-kvichak": { primary: "naknek", details: ["naknek", "kvichak", "alagnak"] },
  "egegik": { primary: "egegik", details: ["egegik"] },
  "ugashik": { primary: "ugashik", details: ["ugashik"] },
  "nushagak": { primary: "nushagak", details: ["nushagak", "wood", "igushik"] },
  "togiak": { primary: "togiak", details: ["togiak"] },
};

function k(date: string, riverKey: string) {
  return `${date}__${riverKey}`;
}

async function main() {
  const year = Number(process.argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/computeDerivedYear.ts <year>");

  const db = initFirestore();
  const batchData = await loadYear(year);

  const issues = validateYearBatch(batchData);
  assertNoErrors(issues);

  const updatedAt = new Date().toISOString();

  const escMap = new Map<string, EscRow>();
  for (const r of batchData.rivers) {
    escMap.set(k(r.date, r.riverKey), {
      riverKey: r.riverKey,
      method: r.method,
      isOperational: r.isOperational,
      dailyEscapement: r.dailyEscapement,
      cumulativeEscapement: r.cumulativeEscapement ?? null,
    });
  }

  const derived: DerivedRow[] = batchData.ops.map((d) => {
    const driftBoats = d.driftBoats ?? 0;
    const driftOpenHours = d.driftOpenHours ?? 0;
    const driftBoatHours = driftBoats > 0 && driftOpenHours > 0 ? driftBoats * driftOpenHours : 0;

    const totalHarvest = d.catch.total;

    const flags: string[] = [];
    if (totalHarvest === null) flags.push("total_harvest_confidential");
    if (driftBoats <= 0) flags.push("no_drift_boats_registered");
    if (driftOpenHours <= 0) flags.push("no_drift_open_hours");
    if ((d.setOpenHours ?? 0) > 0 && driftOpenHours === 0) flags.push("set_only_or_drift_closed");
    if ((d.notes?.length ?? 0) > 0) flags.push("has_notes");

    const avgCatchPerDriftBoat = totalHarvest !== null && driftBoats > 0 ? totalHarvest / driftBoats : null;
    const fishPerDriftBoatHour = totalHarvest !== null && driftBoatHours > 0 ? totalHarvest / driftBoatHours : null;

    const map = DISTRICT_RIVERS[d.districtKey];
    const details: DerivedRow["escapementDetails"] = [];
    let primary: DerivedRow["escapementPrimary"] = null;

    if (map) {
      for (const rk2 of map.details) {
        const e = escMap.get(k(d.date, rk2));
        details.push({
          riverKey: rk2,
          method: e?.method ?? "tower",
          daily: e?.dailyEscapement ?? null,
          cumulative: (e?.cumulativeEscapement ?? null) as number | null,
          isOperational: e?.isOperational ?? false,
        });
      }
      const e = escMap.get(k(d.date, map.primary));
      primary = {
        riverKey: map.primary,
        method: e?.method ?? "tower",
        daily: e?.dailyEscapement ?? null,
        cumulative: (e?.cumulativeEscapement ?? null) as number | null,
        isOperational: e?.isOperational ?? false,
      };
    }

    return {
      year: d.year,
      date: d.date,
      districtKey: d.districtKey,

      driftBoats,
      driftOpenHours,
      driftBoatHours,

      totalHarvest,

      avgCatchPerDriftBoat,
      fishPerDriftBoatHour,

      bestDistrictKey_avgCatchPerDriftBoat: null,
      bestValue_avgCatchPerDriftBoat: null,
      teleportMOI_avgCatchPerDriftBoat: null,

      escapementPrimary: primary,
      escapementDetails: details,

      flags,
      updatedAt,
    };
  });

  const byDate = new Map<string, DerivedRow[]>();
  for (const row of derived) {
    const arr = byDate.get(row.date) ?? [];
    arr.push(row);
    byDate.set(row.date, arr);
  }

  const dailyBest: Array<{
    year: number;
    date: string;
    bestDistrictKey_avgCatchPerDriftBoat: string | null;
    bestValue_avgCatchPerDriftBoat: number | null;
    eligibleCount: number;
    updatedAt: string;
  }> = [];

  for (const [date, rows] of byDate.entries()) {
    const eligible = rows.filter(
      (r) => r.driftOpenHours > 0 && r.driftBoats > 0 && r.avgCatchPerDriftBoat !== null
    );

    let bestKey: string | null = null;
    let bestVal: number | null = null;

    for (const r of eligible) {
      const v = r.avgCatchPerDriftBoat!;
      if (bestVal === null || v > bestVal) {
        bestVal = v;
        bestKey = r.districtKey;
      }
    }

    for (const r of rows) {
      r.bestDistrictKey_avgCatchPerDriftBoat = bestKey;
      r.bestValue_avgCatchPerDriftBoat = bestVal;
      if (bestVal !== null && r.avgCatchPerDriftBoat !== null && bestVal > 0) {
        r.teleportMOI_avgCatchPerDriftBoat = 1 - r.avgCatchPerDriftBoat / bestVal;
      } else {
        r.teleportMOI_avgCatchPerDriftBoat = null;
      }
    }

    dailyBest.push({
      year,
      date,
      bestDistrictKey_avgCatchPerDriftBoat: bestKey,
      bestValue_avgCatchPerDriftBoat: bestVal,
      eligibleCount: eligible.length,
      updatedAt,
    });
  }

  const baseRef = db.collection("historical").doc(String(year));

  async function commitInChunks<T>(
    items: T[],
    toDoc: (b: FirebaseFirestore.WriteBatch, item: T) => void,
    label: string
  ) {
    const CHUNK = 450;
    let written = 0;
    for (let i = 0; i < items.length; i += CHUNK) {
      const chunk = items.slice(i, i + CHUNK);
      const b = db.batch();
      for (const item of chunk) toDoc(b, item);
      await b.commit();
      written += chunk.length;
      console.log(`✅ wrote ${written}/${items.length} ${label}`);
    }
  }

  await commitInChunks(
    derived,
    (b, r) => {
      const id = `${r.date}__${r.districtKey}`;
      const ref = baseRef.collection("dailyDerived").doc(id);
      b.set(ref, r, { merge: true });
    },
    "dailyDerived rows"
  );

  await commitInChunks(
    dailyBest,
    (b, r) => {
      const ref = baseRef.collection("dailyBest").doc(r.date);
      b.set(ref, r, { merge: true });
    },
    "dailyBest rows"
  );

  console.log(`🎉 Done computing derived metrics for year ${year}`);
}

main().catch((e) => {
  console.error("DERIVED FAILED:", e);
  process.exit(1);
});

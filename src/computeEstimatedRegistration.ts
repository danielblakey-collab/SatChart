/**
 * computeEstimatedRegistration.ts
 *
 * Writes estimated registration into:
 *   historical/<year>/dailyDerived_v2/<date>__<districtKey>
 *
 * Fields written (merge):
 * - year, date, districtKey
 * - estimatedDriftBoats: number | null
 * - registrationSource: "estimated_from_deliveries" | "carried_forward" | "unknown"
 * - estimationDetails: { ... }
 * - updatedAt
 *
 * NOTE:
 * - This does NOT overwrite observed registration in dailyDistrictOps.
 * - It estimates ONLY in the estimate window (default 07-17..08-03).
 *
 * Usage:
 *   npx ts-node src/computeEstimatedRegistration.ts 2024 --dry-run
 *   npx ts-node src/computeEstimatedRegistration.ts 2024 --write
 *
 * Optional overrides:
 *   --cal-start=YYYY-MM-DD --cal-end=YYYY-MM-DD
 *   --est-start=YYYY-MM-DD --est-end=YYYY-MM-DD
 *   --clamp=0.20      (max daily decrease clamp; 0 disables)
 *   --clamp-up=0.60   (max daily increase clamp; 0 disables)
 *   --cap-mult=1.15   (cap vs max observed)
 */

import FirebaseFirestore from "firebase-admin/firestore";
import { initFirestore } from "./firestore";

type DistrictKey = "naknek-kvichak" | "egegik" | "ugashik" | "nushagak" | "togiak";
type RegSource = "estimated_from_deliveries" | "carried_forward" | "unknown";

type OpsDoc = {
  year: number;
  date: string;
  districtKey: DistrictKey;

  driftOpenHours?: number | null;

  driftBoats?: number | null;
  deliveries?: {
    drift?: number | null;
    set?: number | null;
    source?: string;
  };

  flags?: string[];
  notes?: string[];
};

function parseArgs(argv: string[]) {
  const year = Number(argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/computeEstimatedRegistration.ts <year> [--write|--dry-run]");

  const write = argv.includes("--write");
  const dryRun = argv.includes("--dry-run") || !write;

  const calibrationStart = argv.find(a => a.startsWith("--cal-start="))?.split("=")[1] ?? `${year}-06-12`;
  const calibrationEnd = argv.find(a => a.startsWith("--cal-end="))?.split("=")[1] ?? `${year}-07-16`;

  const estimateStart = argv.find(a => a.startsWith("--est-start="))?.split("=")[1] ?? `${year}-07-17`;
  const estimateEnd = argv.find(a => a.startsWith("--est-end="))?.split("=")[1] ?? `${year}-08-03`;

  const clampPct = Number(argv.find(a => a.startsWith("--clamp="))?.split("=")[1] ?? "0.20");
  const clampUp = Number(argv.find(a => a.startsWith("--clamp-up="))?.split("=")[1] ?? "0.60");
  const capMult = Number(argv.find(a => a.startsWith("--cap-mult="))?.split("=")[1] ?? "1.15");

  return { year, write, dryRun, calibrationStart, calibrationEnd, estimateStart, estimateEnd, clampPct, clampUp, capMult };
}

function safeNum(v: any): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function clamp(v: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, v));
}

async function fetchOpsRows(
  db: FirebaseFirestore.Firestore,
  year: number,
  startDate: string,
  endDate: string
): Promise<OpsDoc[]> {
  const snap = await db
    .collection("historical")
    .doc(String(year))
    .collection("dailyDistrictOps")
    .where("date", ">=", startDate)
    .where("date", "<=", endDate)
    .orderBy("date")
    .get();

  return snap.docs.map(d => d.data() as OpsDoc);
}

async function main() {
  const { year, write, dryRun, calibrationStart, calibrationEnd, estimateStart, estimateEnd, clampPct, clampUp, capMult } =
    parseArgs(process.argv);

  const db = initFirestore();

  const districts: DistrictKey[] = ["naknek-kvichak", "egegik", "ugashik", "nushagak", "togiak"];

  // 1) Calibration window: use observed boats + drift deliveries (hours gate softened for hours-not-reported cases)
  const calibRows = await fetchOpsRows(db, year, calibrationStart, calibrationEnd);

  const calib: Record<
    DistrictKey,
    { deliveriesPerBoat: number | null; maxObservedBoats: number; samples: number; sumDeliveries: number; sumBoatDays: number }
  > = Object.fromEntries(
    districts.map(dk => [dk, { deliveriesPerBoat: null, maxObservedBoats: 0, samples: 0, sumDeliveries: 0, sumBoatDays: 0 }])
  ) as any;

  for (const dk of districts) {
    const rows = calibRows.filter(r => r.districtKey === dk);

    let sumDeliveries = 0;
    let sumBoatDays = 0;
    let maxBoats = 0;
    let samples = 0;

    let lastBoats: number | null = null;

    for (const r of rows) {
      const boatsHere = safeNum(r.driftBoats);
      if (boatsHere != null && boatsHere > 0) lastBoats = boatsHere;

      const del = safeNum(r.deliveries?.drift);
      const openMaybe = safeNum(r.driftOpenHours);

      // Treat “hours missing / not reported” as OK for calibration.
      // Also: if hours are 0 but deliveries exist, treat as hours-not-reported and allow.
      const hoursOk = openMaybe == null ? true : (openMaybe > 0 || (del != null && del > 0));

      // Use observed boats if present; otherwise carry-forward the last observed boats
      const boatsUsed = boatsHere != null ? boatsHere : lastBoats;

      if (boatsUsed != null && boatsUsed > 0 && del != null && del >= 0 && hoursOk) {
        sumDeliveries += del;
        sumBoatDays += boatsUsed; // boat-days proxy
        samples++;
      }

      if (boatsHere != null && boatsHere > maxBoats) maxBoats = boatsHere;
    }

    const deliveriesPerBoat = sumBoatDays > 0 ? sumDeliveries / sumBoatDays : null;
    calib[dk] = { deliveriesPerBoat, maxObservedBoats: maxBoats, samples, sumDeliveries, sumBoatDays };
  }

  // 2) Estimation window: post-registration
  const estRows = await fetchOpsRows(db, year, estimateStart, estimateEnd);

  const updates: Array<{ docId: string; patch: Record<string, any> }> = [];

  for (const dk of districts) {
    const rows = estRows
      .filter(r => r.districtKey === dk)
      .slice()
      .sort((a, b) => a.date.localeCompare(b.date));

    const c = calib[dk];
    const ratio = c.deliveriesPerBoat;

    let lastEst: number | null = null;

    for (const r of rows) {
      const date = r.date;
      const docId = `${date}__${dk}`;

      const driftDeliveries = safeNum(r.deliveries?.drift);

      let est: number | null = null;
      let source: RegSource = "unknown";
      let reason = "";

      if (ratio != null && driftDeliveries != null) {
        // Post-7/16: boats often deliver ~1.0–1.5x/day; keep ratio in that realistic band.
        const ratioEff = clamp(ratio, 1.0, 1.5);

        est = driftDeliveries / ratioEff;
        source = "estimated_from_deliveries";
        reason = "deliveries_over_calibrated_deliveriesPerBoat|ratio_bounded_1_to_1p5";

        // cap (prevents absurd spikes)
        const cap = c.maxObservedBoats > 0 ? c.maxObservedBoats * capMult : Number.POSITIVE_INFINITY;
        est = clamp(est, 0, cap);

        // Asymmetric clamp: allow swelling (up) more than contraction (down)
        if (lastEst != null && (clampPct > 0 || clampUp > 0)) {
          const lo = lastEst * (1 - Math.max(0, clampPct));
          const hi = lastEst * (1 + Math.max(0, clampUp));
          est = clamp(est, lo, hi);
          reason += "|clamped_asymmetric";
        }

        lastEst = est;
      } else if (lastEst != null) {
        est = lastEst;
        source = "carried_forward";
        reason = "no_deliveries_or_no_ratio";
      } else {
        est = null;
        source = "unknown";
        reason = "no_ratio_and_no_prev";
      }

      updates.push({
        docId,
        patch: {
          year,
          date,
          districtKey: dk,

          estimatedDriftBoats: est != null ? Math.round(est) : null,
          registrationSource: source,

          estimationDetails: {
            method: source,
            reason,

            driftDeliveries: driftDeliveries ?? null,
            deliveriesPerBoat: ratio,
            deliveriesPerBoatEffective: (ratio != null ? clamp(ratio, 1.0, 1.5) : null),

            calibrationWindow: `${calibrationStart}..${calibrationEnd}`,
            estimateWindow: `${estimateStart}..${estimateEnd}`,
            calibrationSamples: c.samples,
            sumDeliveries: c.sumDeliveries,
            sumBoatDays: c.sumBoatDays,
            maxObservedBoats: c.maxObservedBoats,
            capMult,
            clampPct,
            clampUp,
          },

          updatedAt: new Date().toISOString(),
        },
      });
    }
  }

  // 3) Summary
  const summary = updates.reduce((acc, u) => {
    const src = u.patch.registrationSource as RegSource;
    acc[src] = (acc[src] ?? 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  console.log("Calibration:");
  for (const dk of districts) {
    const c = calib[dk];
    console.log(
      `  ${dk}: deliveriesPerBoat=${c.deliveriesPerBoat?.toFixed(4) ?? "null"} samples=${c.samples} maxBoats=${c.maxObservedBoats}`
    );
  }

  console.log("Planned derived_v2 updates:", updates.length, summary);
  console.log("Mode:", dryRun ? "DRY RUN (no writes)" : "WRITE");

  if (dryRun) return;

  // 4) Write to dailyDerived_v2
  const baseRef = db.collection("historical").doc(String(year)).collection("dailyDerived_v2");

  const CHUNK = 450;
  let written = 0;

  for (let i = 0; i < updates.length; i += CHUNK) {
    const chunk = updates.slice(i, i + CHUNK);
    const batch = db.batch();

    for (const u of chunk) {
      const ref = baseRef.doc(u.docId);
      batch.set(ref, u.patch, { merge: true });
    }

    await batch.commit();
    written += chunk.length;
    console.log(`✅ wrote ${written}/${updates.length} dailyDerived_v2 estimated registration docs`);
  }
}

main().catch(err => {
  console.error("FAILED:", err);
  process.exit(1);
});
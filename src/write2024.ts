import { initFirestore } from "./firestore";
import { load2024 } from "./loaders/2024";
import { validateYearBatch, assertNoErrors } from "./batchValidation";

/**
 * Firestore layout:
 * historical/{year}/yearMeta/meta
 * historical/{year}/dailyDistrictOps/{date__districtKey}
 * historical/{year}/dailyRiverEscapement/{date__riverKey}
 * historical/{year}/yearDistrictForecastOutcome/{districtKey}
 */
async function main() {
  const db = initFirestore();
  const batchData = await load2024();

  const issues = validateYearBatch(batchData);
  assertNoErrors(issues);

  const year = batchData.meta.year;
  const baseRef = db.collection("historical").doc(String(year));

  // 1) Write yearMeta
  await baseRef.collection("yearMeta").doc("meta").set({
    ...batchData.meta,
    validation: {
      warnings: issues.filter(i => i.severity === "warn"),
    },
    updatedAt: new Date().toISOString(),
  });

  // Helper: commit in chunks (Firestore batch limit is 500)
  async function commitInChunks<T>(
    items: T[],
    toDoc: (b: FirebaseFirestore.WriteBatch, item: T) => void,
    label: string
  ) {
    const CHUNK = 450; // keep margin
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

  // 2) Write forecasts
  await commitInChunks(
    batchData.forecasts,
    (b, f) => {
      const ref = baseRef.collection("yearDistrictForecastOutcome").doc(f.districtKey);
      b.set(ref, { ...f, updatedAt: new Date().toISOString() }, { merge: true });
    },
    "forecast rows"
  );

  // 3) Write dailyDistrictOps
  await commitInChunks(
    batchData.ops,
    (b, d) => {
      const id = `${d.date}__${d.districtKey}`;
      const ref = baseRef.collection("dailyDistrictOps").doc(id);
      b.set(ref, { ...d, updatedAt: new Date().toISOString() }, { merge: true });
    },
    "dailyDistrictOps rows"
  );

  // 4) Write dailyRiverEscapement
  await commitInChunks(
    batchData.rivers,
    (b, r) => {
      const id = `${r.date}__${r.riverKey}`;
      const ref = baseRef.collection("dailyRiverEscapement").doc(id);
      b.set(ref, { ...r, updatedAt: new Date().toISOString() }, { merge: true });
    },
    "dailyRiverEscapement rows"
  );

  console.log("🎉 Done writing year", year);
}

main().catch((e) => {
  console.error("WRITE FAILED:", e);
  process.exit(1);
});

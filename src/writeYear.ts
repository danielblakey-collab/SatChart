import { initFirestore } from "./firestore";
import { loadYear } from "./loaders";
import { validateYearBatch, assertNoErrors } from "./batchValidation";
import { getDriftShare } from "./alloc/gearShare";
async function main() {
  const year = Number(process.argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/writeYear.ts <year>");

  const db = initFirestore();
  const batchData = await loadYear(year);

const issues = validateYearBatch(batchData);

// Allow building years that are still in progress (like 2023 loader being filled in)
// Usage: npx ts-node src/writeYear.ts 2023 --allow-incomplete
const allowIncomplete = process.argv.includes("--allow-incomplete");
if (!allowIncomplete) {
  assertNoErrors(issues);
} else {
  console.log("⚠️ allow-incomplete enabled; skipping assertNoErrors");
  console.log("Warnings/errors:", issues);
}

  const baseRef = db.collection("historical").doc(String(year));
  const driftShareByDistrict = {
    "naknek-kvichak": getDriftShare(year, "naknek-kvichak"),
    "egegik": getDriftShare(year, "egegik"),
    "ugashik": getDriftShare(year, "ugashik"),
    "nushagak": getDriftShare(year, "nushagak"),
    "togiak": getDriftShare(year, "togiak"),
  };
// yearMeta
await baseRef.collection("yearMeta").doc("meta").set({
  ...batchData.meta,

  allocation: {
    driftShareByDistrict,
  },

  validation: { warnings: issues.filter(i => i.severity === "warn") },
  updatedAt: new Date().toISOString(),
});

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
    batchData.forecasts,
    (b, f) => {
      const ref = baseRef.collection("yearDistrictForecastOutcome").doc((f as any).districtKey);
      b.set(ref, { ...(f as any), updatedAt: new Date().toISOString() }, { merge: true });
    },
    "forecast rows"
  );

  await commitInChunks(
    batchData.ops,
    (b, d: any) => {
      const ref = baseRef.collection("dailyDistrictOps").doc(`${d.date}__${d.districtKey}`);
      b.set(ref, { ...d, updatedAt: new Date().toISOString() }, { merge: true });
    },
    "dailyDistrictOps rows"
  );

  await commitInChunks(
    batchData.rivers,
    (b, r: any) => {
      const ref = baseRef.collection("dailyRiverEscapement").doc(`${r.date}__${r.riverKey}`);
      b.set(ref, { ...r, updatedAt: new Date().toISOString() }, { merge: true });
    },
    "dailyRiverEscapement rows"
  );

  console.log(`🎉 Done writing year ${year}`);
}

main().catch((e) => {
  console.error("WRITE FAILED:", e);
  process.exit(1);
});

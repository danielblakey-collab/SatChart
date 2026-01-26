/**
 * Delete 2024 Firestore subcollections safely in batches.
 *
 * Requires:
 *   export GOOGLE_APPLICATION_CREDENTIALS=".../service-account.json"
 *
 * Run:
 *   node tmp/delete_2024.js
 */

const admin = require("firebase-admin");

if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error("GOOGLE_APPLICATION_CREDENTIALS is not set.");
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

async function deleteCollection(collRef, batchSize = 400) {
  let deleted = 0;

  while (true) {
    const snap = await collRef.orderBy("__name__").limit(batchSize).get();
    if (snap.empty) break;

    const batch = db.batch();
    for (const doc of snap.docs) batch.delete(doc.ref);
    await batch.commit();

    deleted += snap.size;
    console.log(`✅ deleted ${deleted} docs from ${collRef.path}`);
  }

  console.log(`🎉 finished ${collRef.path}`);
}

async function main() {
  const yearDoc = db.collection("historical").doc("2024");

  const subcollections = [
    "dailyDistrictOps",
    "dailyRiverEscapement",
    "dailyDerived",
    "dailyDerived_v2",
    "yearDistrictForecastOutcome",
    "yearMeta",
  ];

  for (const name of subcollections) {
    const ref = yearDoc.collection(name);
    console.log(`\n--- Deleting ${ref.path} ---`);
    await deleteCollection(ref, 400);
  }

  // Finally delete the year doc itself (only removes doc fields, not subcollections—already removed above)
  await yearDoc.delete().catch(() => {});
  console.log("\n✅ deleted historical/2024 doc");
}

main().catch((e) => {
  console.error("DELETE FAILED:", e);
  process.exit(1);
});

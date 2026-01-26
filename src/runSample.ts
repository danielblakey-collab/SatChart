import { validateYearBatch } from "./batchValidation";
import { loadSample } from "./loaders/sample";

async function main() {
  console.log("Starting sample validation...");

  const batch = await loadSample();
  console.log("Loaded sample year:", batch.meta.year);

  const issues = validateYearBatch(batch);

  console.log(`Issues found: ${issues.length}`);
  for (const i of issues) {
    console.log(`${i.severity.toUpperCase()}: ${i.code} — ${i.message}`);
  }

  console.log("Done.");
}

main().catch((e) => {
  console.error("RUN FAILED:", e);
  process.exit(1);
});

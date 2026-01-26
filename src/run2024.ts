import { validateYearBatch } from "./batchValidation";
import { load2024 } from "./loaders/2024";

async function main() {
  console.log("Starting 2024 validation...");

  const batch = await load2024();
  console.log("Loaded year:", batch.meta.year);
  console.log("Ops rows:", batch.ops.length);
  console.log("River rows:", batch.rivers.length);

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

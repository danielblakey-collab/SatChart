import { loadYear } from "./loaders";
import { validateYearBatch } from "./batchValidation";

async function main() {
  const year = Number(process.argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/runYear.ts <year>");

  console.log(`Validating ${year}...`);
  const batch = await loadYear(year);

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

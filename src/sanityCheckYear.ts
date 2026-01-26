import { loadYear } from "./loaders";
import { validateYearBatch } from "./batchValidation";

type Issue = { severity: "error" | "warn"; message: string };

function fmt(n: number) {
  return n.toLocaleString("en-US");
}

async function main() {
  const year = Number(process.argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/sanityCheckYear.ts <year>");

  const batch = await loadYear(year);

  // Run your existing validator too (so we get a single report)
  const baseIssues = validateYearBatch(batch);
  const issues: Issue[] = baseIssues.map(i => ({ severity: i.severity, message: `[${i.code}] ${i.message}` }));

  // ---- River checks ----
  const byRiver = new Map<string, typeof batch.rivers>();
  for (const r of batch.rivers) {
    const arr = byRiver.get(r.riverKey) ?? [];
    arr.push(r);
    byRiver.set(r.riverKey, arr);
  }

  for (const [riverKey, rows] of byRiver.entries()) {
    rows.sort((a, b) => a.date.localeCompare(b.date));

    let prevCum: number | null = null;
    let prevDate: string | null = null;

    for (const row of rows) {
      const daily = row.dailyEscapement;
      const cum = row.cumulativeEscapement ?? null;

      // Monotonic cumulative (hard)
      if (typeof cum === "number") {
        if (prevCum !== null && cum < prevCum) {
          issues.push({
            severity: "error",
            message: `River ${riverKey}: cumulative decreased ${fmt(prevCum)} -> ${fmt(cum)} on ${row.date}`,
          });
        }

        // Arithmetic check (warn): prevCum + daily == cum
        if (prevCum !== null && row.isOperational && typeof daily === "number") {
          const expected: number = prevCum + daily;
          if (expected !== cum) {
            issues.push({
              severity: "warn",
              message: `River ${riverKey}: cum arithmetic mismatch on ${row.date} (prevCum ${fmt(prevCum)} + daily ${fmt(daily)} = ${fmt(expected)}; got ${fmt(cum)})`,
            });
          }
        }

        prevCum = cum;
      } else {
        // cum missing; keep prevCum
      }

      prevDate = row.date;
      void prevDate;
    }
  }

  // ---- Ops checks ----
  for (const d of batch.ops) {
    const computed = d.driftPermits - d.dualPermits;
    if (d.driftBoats !== computed) {
      issues.push({
        severity: "error",
        message: `Ops ${d.date} ${d.districtKey}: driftBoats mismatch (permits ${d.driftPermits} - dual ${d.dualPermits} = ${computed}; got ${d.driftBoats})`,
      });
    }

    const total = d.catch.total;
    const sockeye = (d.catch as any).sockeye;

    if (typeof total === "number" && typeof sockeye === "number" && sockeye > total) {
      issues.push({
        severity: "warn",
        message: `Ops ${d.date} ${d.districtKey}: sockeye (${fmt(sockeye)}) > total (${fmt(total)})`,
      });
    }
  }

  const errs = issues.filter(i => i.severity === "error");
  const warns = issues.filter(i => i.severity === "warn");

  console.log(`Sanity check ${year}: ${errs.length} errors, ${warns.length} warnings`);
  for (const e of errs) console.log("ERROR:", e.message);
  for (const w of warns) console.log("WARN :", w.message);

  if (errs.length) process.exit(1);
}

main().catch((e) => {
  console.error("SANITY CHECK FAILED:", e);
  process.exit(1);
});

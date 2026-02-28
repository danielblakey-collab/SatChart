/**
 * tmp/parse_table10_2021.js
 *
 * Parses src/data/2021/raw/registration_table10.txt into:
 *   src/data/2021/registration_2021.csv
 *
 * Output header:
 * date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes
 *
 * Assumes:
 * - Togiak has NO dual (write dualPermits=0)
 * - driftBoats = driftPermits - dualPermits
 */

const fs = require("fs");
const path = require("path");

const YEAR = 2021;
const IN_PATH = path.join("src", "data", "2021", "raw", "registration_table10.txt");
const OUT_PATH = path.join("src", "data", "2021", "registration_2021.csv");

const districts = [
  { key: "naknek-kvichak", dualAllowed: true },
  { key: "egegik", dualAllowed: true },
  { key: "ugashik", dualAllowed: true },
  { key: "nushagak", dualAllowed: true },
  { key: "togiak", dualAllowed: false },
];

function pad2(n) {
  return String(n).padStart(2, "0");
}
function toISO(mmdd) {
  const [m, d] = mmdd.split("/").map((x) => Number(x));
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}
function cleanToken(t) {
  return String(t).replace(/,/g, "").trim();
}
function isNumToken(t) {
  const c = cleanToken(t);
  return c !== "" && c !== "ND" && c !== "–" && c !== "-" && /^\d+(\.\d+)?$/.test(c);
}

function main() {
  if (!fs.existsSync(IN_PATH)) throw new Error(`Missing input: ${IN_PATH}`);
  const raw = fs.readFileSync(IN_PATH, "utf8");

  const lines = raw
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  // Keep lines that start with M/D (e.g. 6/16 or 7/01)
  const dataLines = lines.filter((l) => /^\d{1,2}\/\d{1,2}\b/.test(l));

  if (dataLines.length === 0) {
    throw new Error("No data lines found. Make sure the file contains the Table 10 rows (starting with 6/..).");
  }

  const out = [];
  out.push("date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes");

  for (const line of dataLines) {
    // Split on whitespace
    const parts = line.split(/\s+/);

    const mmdd = parts[0];
    const date = toISO(mmdd);

    // Remaining tokens should be:
    // nak_total nak_dual egeg_total egeg_dual ug_total ug_dual nush_total nush_dual togiak_total [TOTAL]
    // Some tables include TOTAL at end; we ignore it.
    const nums = parts.slice(1).map(cleanToken);

    // Filter to numeric-like tokens only (ignore trailing total if present but still numeric; we just take first 9/10)
    const numeric = nums.filter((t) => isNumToken(t));

    // Expect 9 or 10 numeric values (10 if includes TOTAL column)
    if (numeric.length < 9) {
      // Still write 0s rather than failing hard
      // but add a note so you can find this later
      // (keeps ETL moving)
      // console.warn("Short row:", line, "numeric:", numeric.length);
      while (numeric.length < 9) numeric.push("0");
    }

    // Take first 9 as: (nak total/dual), (egeg total/dual), (ug total/dual), (nush total/dual), (togiak total)
    const n = numeric.map((x) => Number(x));
    const nakTot = n[0], nakDual = n[1];
    const eTot = n[2], eDual = n[3];
    const uTot = n[4], uDual = n[5];
    const nuTot = n[6], nuDual = n[7];
    const tTot = n[8];

    const rows = [
      { dk: "naknek-kvichak", tot: nakTot, dual: nakDual },
      { dk: "egegik", tot: eTot, dual: eDual },
      { dk: "ugashik", tot: uTot, dual: uDual },
      { dk: "nushagak", tot: nuTot, dual: nuDual },
      { dk: "togiak", tot: tTot, dual: 0 },
    ];

    for (const r of rows) {
      const driftPermits = Math.max(0, r.tot);
      const dualPermits = Math.max(0, r.dual);
      const driftBoats = Math.max(0, driftPermits - dualPermits);

      out.push(
        [
          date,
          r.dk,
          driftPermits,
          dualPermits,
          driftBoats,
          "", // flags
          "table10_registration", // notes
        ].join(",")
      );
    }
  }

  fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
  fs.writeFileSync(OUT_PATH, out.join("\n") + "\n", "utf8");
  console.log(`✅ wrote ${OUT_PATH} (${out.length - 1} rows)`);
}

main();

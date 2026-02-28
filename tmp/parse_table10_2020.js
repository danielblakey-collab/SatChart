// tmp/parse_table10_2020.js
const fs = require("fs");
const path = require("path");

const YEAR = 2020;
const IN_PATH = `src/data/${YEAR}/raw/registration_table10.txt`;
const OUT_PATH = `src/data/${YEAR}/registration_${YEAR}.csv`;

const DISTRICTS = [
  { dk: "naknek-kvichak", idxTotal: 0, idxDual: 1 },
  { dk: "egegik", idxTotal: 2, idxDual: 3 },
  { dk: "ugashik", idxTotal: 4, idxDual: 5 },
  { dk: "nushagak", idxTotal: 6, idxDual: 7 },
  // togiak has no dual; table has total only
  { dk: "togiak", idxTotal: 8, idxDual: null },
];

function pad2(n) { return String(n).padStart(2, "0"); }
function isoFromMD(md) {
  const [m, d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}
function cleanNum(s) {
  if (s == null) return null;
  const t = String(s).trim();
  if (!t || t === "-" || t === "–" || t.toUpperCase() === "ND") return null;
  const n = Number(t.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

function main() {
  if (!fs.existsSync(IN_PATH)) throw new Error(`Missing ${IN_PATH}`);
  const raw = fs.readFileSync(IN_PATH, "utf8");

  // Pull all lines; allow indentation/wrapping
  const lines = raw.split(/\r?\n/);

  const out = [];
  out.push("date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes");

  let rows = 0;

  for (const line0 of lines) {
    const line = line0.trim();
    if (!line) continue;

    // Skip headers/footers
    if (/^Table\b/i.test(line)) continue;
    if (/^Note:/i.test(line)) continue;
    if (/^Average/i.test(line)) continue;

    // Find a date token anywhere on the line: 6/1, 7/16, 7/01, etc.
    const m = line.match(/(?:^|\s)(\d{1,2}\/\d{1,2})(?:\s|$)/);
    if (!m) continue;

    const md = m[1];
    const date = isoFromMD(md);

    // Extract all numbers after the date token.
    // This works even if the line has commas.
    const after = line.slice(line.indexOf(md) + md.length).trim();
    const nums = (after.match(/-?\d[\d,]*/g) || []).map(x => cleanNum(x)).filter(x => x != null);

    // We expect: NK total, NK dual, EG total, EG dual, UG total, UG dual, NU total, NU dual, TO total, (Total b maybe)
    // So we need at least 9 numeric values.
    if (nums.length < 9) continue;

    for (const d of DISTRICTS) {
      const total = nums[d.idxTotal];
      const dual = d.idxDual == null ? 0 : nums[d.idxDual];
      const driftPermits = total ?? 0;
      const dualPermits = dual ?? 0;
      const driftBoats = (driftPermits != null && dualPermits != null) ? (driftPermits - dualPermits) : null;

      const flags = ["table10_registration"];
      if (d.dk === "togiak") flags.push("togiak_no_dual_by_regulation");

      out.push([
        date,
        d.dk,
        driftPermits,
        dualPermits,
        driftBoats,
        flags.join("|"),
        ""
      ].join(","));
      rows++;
    }
  }

  if (rows === 0) {
    throw new Error(
      "Parsed 0 rows. Your pasted Table 10 text likely wrapped badly. " +
      "Make sure the date lines (6/1, 6/2, …) are present in registration_table10.txt."
    );
  }

  fs.writeFileSync(OUT_PATH, out.join("\n") + "\n", "utf8");
  console.log(`✅ wrote ${OUT_PATH} (${rows} rows)`);
}

main();
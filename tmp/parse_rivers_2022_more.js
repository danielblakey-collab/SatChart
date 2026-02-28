const fs = require("fs");

const YEAR = 2022;

function pad2(n) { return String(n).padStart(2, "0"); }
function iso(md) {
  const [m, d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}

function toIntToken(s) {
  if (s == null) return null;
  s = String(s).trim();
  if (!s) return null;
  if (s === "-" || s === "–" || s.toUpperCase() === "ND") return null;
  const n = Number(s.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

// Extract numeric-ish tokens AFTER the date.
// e.g. "6/20 246 246 6,228 55,428" -> [246,246,6228,55428]
function extractNumberTokens(line) {
  // remove footnote letters like "a" right after date
  line = line.replace(/^(\d{1,2}\/\d{1,2})\s+[a-z]\b/i, "$1");
  const parts = line.trim().split(/\s+/);
  if (!/^\d{1,2}\/\d{1,2}$/.test(parts[0])) return null;
  const dateMD = parts[0];

  const nums = [];
  for (let i = 1; i < parts.length; i++) {
    const v = toIntToken(parts[i]);
    // keep nulls out; raw tables omit ND cells anyway
    if (v != null) nums.push(v);
  }
  return { dateMD, nums };
}

function row(dateISO, riverKey, method, isOperational, daily, cum, flags, notes) {
  return [
    dateISO,
    riverKey,
    method,
    isOperational ? "true" : "false",
    daily == null ? "" : String(daily),
    cum == null ? "" : String(cum),
    (flags && flags.length) ? flags.join("|") : "",
    (notes && notes.length) ? notes.join("|") : ""
  ].join(",");
}

// ---- Table 7 (sonar, Nushagak River) ----
// We only use Sockeye daily/cum (columns 1 and 2 after date).
function parseSonarTable7(path) {
  const raw = fs.readFileSync(path, "utf8").split(/\r?\n/);
  const out = [];
  for (let line of raw) {
    line = line.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;
    const parts = line.split(/\s+/);
    const dateISO = iso(parts[0]);

    const sockeyeDaily = toIntToken(parts[1]);
    const sockeyeCum = toIntToken(parts[2]);

    if (sockeyeDaily == null && sockeyeCum == null) continue;

    out.push(row(dateISO, "nushagak", "sonar", true, sockeyeDaily, sockeyeCum, [], []));
  }
  return out;
}

// ---- Table 8 (eastside towers) ----
// Rivers appear left-to-right, but some early-season lines only include some rivers.
// We:
//  - require an EVEN number of numeric tokens (pairs)
//  - assign pairs left-to-right across [kvichak,naknek,alagnak,egegik,ugashik]
//  - enforce monotonic cumulative per river:
//      if cum < lastCum and daily exists -> set cum = lastCum + daily, flag repair
function parseEastsideTable8(path) {
  const raw = fs.readFileSync(path, "utf8").split(/\r?\n/);
  const rivers = ["kvichak", "naknek", "alagnak", "egegik", "ugashik"];

  const lastCumByRiver = Object.fromEntries(rivers.map(r => [r, null]));

  const out = [];
  const skipped = [];

  for (let line of raw) {
    line = line.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;

    const parsed = extractNumberTokens(line);
    if (!parsed) continue;

    const { dateMD, nums } = parsed;
    const dateISO = iso(dateMD);

    if (nums.length < 2) continue;

    // If odd number of tokens, we cannot safely pair daily/cum -> skip.
    if (nums.length % 2 !== 0) {
      skipped.push({ dateISO, reason: "odd_token_count", numsLen: nums.length, line });
      continue;
    }

    const pairCount = Math.min(rivers.length, nums.length / 2);

    for (let i = 0; i < pairCount; i++) {
      const riverKey = rivers[i];
      const daily = nums[i * 2];
      let cum = nums[i * 2 + 1];

      const flags = [];
      const notes = [];

      const lastCum = lastCumByRiver[riverKey];

      // Repair decreasing cumulative using prev+daily when possible
      if (lastCum != null && cum != null && cum < lastCum) {
        if (daily != null) {
          cum = lastCum + daily;
          flags.push("cum_repaired_prev_plus_daily");
          notes.push("table8_alignment_ambiguous_repaired");
        } else {
          // can't repair without daily -> skip this river/date
          skipped.push({ dateISO, riverKey, reason: "cum_decrease_unrepairable", lastCum, cum });
          continue;
        }
      }

      // If cum missing but daily present and we have lastCum, infer
      if (cum == null && daily != null && lastCum != null) {
        cum = lastCum + daily;
        flags.push("cum_inferred_prev_plus_daily");
      }

      if (cum != null) lastCumByRiver[riverKey] = cum;

      out.push(row(dateISO, riverKey, "tower", true, daily, cum, flags, notes));
    }
  }

  if (skipped.length) {
  console.error(`⚠️ eastside skipped ${skipped.length} rows (odd/misaligned). Example:`, skipped[0]);
  }
  return out;
}

function main() {
  const sonarPath = "src/data/2022/raw/sonar_table7_2022.txt";
  const eastPath = "src/data/2022/raw/eastside_table8_2022.txt";

  const rows = [
    ...parseSonarTable7(sonarPath),
    ...parseEastsideTable8(eastPath),
  ];

  process.stdout.write(rows.join("\n") + "\n");
}

main();

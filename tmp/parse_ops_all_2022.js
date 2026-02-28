const fs = require("fs");
const path = require("path");

const YEAR = 2022;
const START = `${YEAR}-06-12`;
const END   = `${YEAR}-08-03`;

const RAW_DIR = `src/data/${YEAR}/raw`;
const OUT_CSV = `src/data/${YEAR}/ops_${YEAR}.csv`;

const DISTRICTS = [
  { key: "naknek-kvichak", file: "naknek_kvichak.txt", mode: "standard" },
  { key: "egegik",         file: "egegik.txt",         mode: "standard" },
  { key: "ugashik",        file: "ugashik.txt",        mode: "standard" },
  { key: "nushagak",       file: "nushagak.txt",       mode: "nushagak" }, // 13.5/24 style hours
  { key: "togiak",         file: "togiak.txt",         mode: "togiak" },   // deliveries only
];

function pad2(n){ return String(n).padStart(2,"0"); }
function isoFromMD(md){
  const [m,d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}
function toNum(x){
  if (x == null) return null;
  let s = String(x).trim();
  if (!s || s === "-" || s === "–" || s.toUpperCase() === "ND") return null;
  s = s.replace(/,/g,"");
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}
function inRange(iso){ return iso >= START && iso <= END; }

function* dateRange(startISO, endISO){
  const s = new Date(startISO + "T00:00:00Z");
  const e = new Date(endISO + "T00:00:00Z");
  for (let d = new Date(s); d <= e; d.setUTCDate(d.getUTCDate() + 1)) {
    yield `${d.getUTCFullYear()}-${pad2(d.getUTCMonth()+1)}-${pad2(d.getUTCDate())}`;
  }
}

function parseStandard(lines, districtKey){
  // expects: M/D driftHours setHours driftDel setDel sockeye ...
  const map = new Map();
  for (const raw of lines){
    let line = raw.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;

    // strip footnote letters immediately after date (e.g. "6/6 a")
    line = line.replace(/^(\d{1,2}\/\d{1,2})\s+[a-z]\b/i, "$1");
    const parts = line.split(/\s+/);
    const md = parts[0];
    const iso = isoFromMD(md);
    if (!inRange(iso)) continue;

    const driftHours = toNum(parts[1]) ?? 0;
    const setHours   = toNum(parts[2]) ?? 0;

    const driftDel   = toNum(parts[3]) ?? 0;
    const setDel     = toNum(parts[4]) ?? 0;

    const sockeye    = toNum(parts[5]);
    const sockeyeDaily = sockeye ?? 0;

    const flags = [];
    const notes = [];

    if ((driftDel > 0 || setDel > 0) && sockeye == null) flags.push("sockeye_missing_confidential_or_not_reported");
    if (parts.length < 6) flags.push("row_incomplete_in_table");

    map.set(iso, {
      date: iso, districtKey,
      driftOpenHours: driftHours,
      setOpenHours: setHours,
      driftDeliveries: driftDel,
      setDeliveries: setDel,
      sockeyeDaily,
      flags: flags.join("|"),
      notes: notes.join("|"),
    });
  }
  return map;
}

function parseTogiak(lines){
  // deliveries only: M/D driftDel setDel sockeye ...
  const map = new Map();
  for (const raw of lines){
    let line = raw.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;
    line = line.replace(/^(\d{1,2}\/\d{1,2})\s+[a-z]\b/i, "$1");
    const parts = line.split(/\s+/);
    const md = parts[0];
    const iso = isoFromMD(md);
    if (!inRange(iso)) continue;

    const driftDel = toNum(parts[1]) ?? 0;
    const setDel   = toNum(parts[2]) ?? 0;

    const sockeye  = toNum(parts[3]);
    const sockeyeDaily = sockeye ?? 0;

    const flags = [];
    if ((driftDel > 0 || setDel > 0) && sockeye == null) flags.push("sockeye_missing_confidential_or_not_reported");

    map.set(iso, {
      date: iso, districtKey: "togiak",
      driftOpenHours: 0,
      setOpenHours: 0,
      driftDeliveries: driftDel,
      setDeliveries: setDel,
      sockeyeDaily,
      flags: flags.join("|"),
      notes: "hours_not_reported_in_table",
    });
  }
  return map;
}

function parseNushagak(lines){
  // Nushagak format: date NushagakHours IgushikHours DriftDel SetDel Sockeye...
  // Hours are like "13.5/24". We will take DRIFT hour as left side of first hours token (Nushagak section),
  // and SET hour as right side of second hours token (Igushik section), since you merge sections anyway.
  const map = new Map();

  // Some PDF copies break rows across lines; we only use lines that start with M/D and have at least drift/set token.
  for (const raw of lines){
    let line = raw.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;
    line = line.replace(/^(\d{1,2}\/\d{1,2})\s+[a-z]\b/i, "$1");
    const parts = line.split(/\s+/);
    const md = parts[0];
    const iso = isoFromMD(md);
    if (!inRange(iso)) continue;

    // Find tokens like 13.5/24
    const fracTokens = parts.filter(p => /^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(p));
    // Sometimes the row is "0/0 0/24" so we expect 2 tokens.
    const h1 = fracTokens[0] ?? "0/0";
    const h2 = fracTokens[1] ?? "0/0";
    const [d1,s1] = h1.split("/").map(toNum);
    const [d2,s2] = h2.split("/").map(toNum);

    // Reasonable merge: driftOpenHours = max(d1,d2) and setOpenHours = max(s1,s2)
    const driftHours = Math.max(d1 ?? 0, d2 ?? 0);
    const setHours = Math.max(s1 ?? 0, s2 ?? 0);

    // Deliveries tend to appear after those tokens; easiest is to grab the first 2 integers after the hour tokens.
    // We'll scan parts and collect numeric ints (excluding the date and the hour tokens).
    const nums = [];
    for (const p of parts.slice(1)) {
      if (/^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(p)) continue;
      const n = toNum(p);
      if (n != null) nums.push(n);
    }

    // We expect: driftDel, setDel, sockeye, ...
    const driftDel = nums[0] != null ? nums[0] : 0;
    const setDel   = nums[1] != null ? nums[1] : 0;
    const sockeye  = nums[2] != null ? nums[2] : null;

    const sockeyeDaily = sockeye ?? 0;

    const flags = [];
    if ((driftDel > 0 || setDel > 0) && sockeye == null) flags.push("sockeye_missing_confidential_or_not_reported");
    if (nums.length < 3) flags.push("row_incomplete_in_table");

    map.set(iso, {
      date: iso, districtKey: "nushagak",
      driftOpenHours: driftHours,
      setOpenHours: setHours,
      driftDeliveries: driftDel,
      setDeliveries: setDel,
      sockeyeDaily,
      flags: flags.join("|"),
      notes: "",
    });
  }

  return map;
}

// ----- Main -----
function readLines(file){
  const p = path.join(RAW_DIR, file);
  if (!fs.existsSync(p)) throw new Error(`Missing raw file: ${p}`);
  return fs.readFileSync(p, "utf8").split(/\r?\n/);
}

const out = [];
out.push("date,districtKey,driftOpenHours,setOpenHours,driftDeliveries,setDeliveries,sockeyeDaily,flags,notes");

for (const d of DISTRICTS){
  const lines = readLines(d.file);
  let map;
  if (d.mode === "togiak") map = parseTogiak(lines);
  else if (d.mode === "nushagak") map = parseNushagak(lines);
  else map = parseStandard(lines, d.key);

  for (const iso of dateRange(START, END)){
    const row = map.get(iso) || {
      date: iso,
      districtKey: d.key,
      driftOpenHours: 0,
      setOpenHours: 0,
      driftDeliveries: 0,
      setDeliveries: 0,
      sockeyeDaily: 0,
      flags: "no_data_in_table",
      notes: "",
    };
    out.push([
      row.date,
      row.districtKey,
      row.driftOpenHours,
      row.setOpenHours,
      row.driftDeliveries,
      row.setDeliveries,
      row.sockeyeDaily,
      row.flags ?? "",
      row.notes ?? "",
    ].join(","));
  }
}

fs.writeFileSync(OUT_CSV, out.join("\n") + "\n", "utf8");
console.log(`✅ wrote ${OUT_CSV} (${out.length - 1} rows)`);

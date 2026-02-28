const fs = require("fs");
const path = require("path");

const YEAR = 2021;
const START = `${YEAR}-06-12`;
const END   = `${YEAR}-08-03`;

const RAW_DIR = `src/data/${YEAR}/raw`;
const OUT_CSV = `src/data/${YEAR}/ops_${YEAR}.csv`;

const DISTRICTS = [
  { key: "naknek-kvichak", file: "naknek_kvichak.txt", mode: "standard" },
  { key: "egegik",         file: "egegik.txt",         mode: "standard" },
  { key: "ugashik",        file: "ugashik.txt",        mode: "standard" },
  { key: "nushagak",       file: "nushagak_exploded.txt", mode: "nushagak_exploded" },
  { key: "togiak",         file: "togiak.txt",         mode: "togiak" },
];

function pad2(n){ return String(n).padStart(2,"0"); }

function isoFromMD(md){
  const [m,d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}

function stripDateFootnote(md){
  return String(md).trim().replace(/^(\d{1,2}\/\d{1,2})[a-z]+$/i, "$1");
}

function toNum(x){
  if (x == null) return null;
  let s = String(x).trim();
  if (!s || s === "-" || s === "–" || s.toUpperCase() === "ND") return null;
  s = s.replace(/,/g,"");
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

function inRange(iso){
  return iso >= START && iso <= END;
}

function* dateRange(startISO, endISO){
  const s = new Date(startISO + "T00:00:00Z");
  const e = new Date(endISO + "T00:00:00Z");
  for (let d = new Date(s); d <= e; d.setUTCDate(d.getUTCDate() + 1)) {
    yield `${d.getUTCFullYear()}-${pad2(d.getUTCMonth()+1)}-${pad2(d.getUTCDate())}`;
  }
}

function readLines(file){
  const p = path.join(RAW_DIR, file);
  if (!fs.existsSync(p)) throw new Error(`Missing raw file: ${p}`);
  return fs.readFileSync(p, "utf8").split(/\r?\n/);
}

/* =========================
   STANDARD DISTRICTS
   ========================= */
function parseStandard(lines, districtKey){
  const map = new Map();

  for (const raw of lines){
    let line = raw.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;

    line = line.replace(/^(\d{1,2}\/\d{1,2})\s+[a-z]\b/i, "$1");

    const parts = line.split(/\s+/);
    const md = stripDateFootnote(parts[0]);
    const iso = isoFromMD(md);
    if (!inRange(iso)) continue;

    const driftHours = toNum(parts[1]) ?? 0;
    const setHours   = toNum(parts[2]) ?? 0;
    const driftDel   = toNum(parts[3]) ?? 0;
    const setDel     = toNum(parts[4]) ?? 0;
    const sockeye    = toNum(parts[5]) ?? 0;

    const flags = [];
    if ((driftDel > 0 || setDel > 0) && parts.length < 6)
      flags.push("sockeye_missing_confidential_or_not_reported");

    map.set(iso, {
      date: iso,
      districtKey,
      driftOpenHours: driftHours,
      setOpenHours: setHours,
      driftDeliveries: driftDel,
      setDeliveries: setDel,
      sockeyeDaily: sockeye,
      flags: flags.join("|"),
      notes: "",
    });
  }

  return map;
}

/* =========================
   TOGIAK – TABLE 19 ONLY
   ========================= */
function parseTogiak(lines){
  // Deliveries-only table (Table 19)
  const map = new Map();

  for (const raw of lines){
    let line = raw.trim();
    if (!/^\d{1,2}\/\d{1,2}\b/.test(line)) continue;

    // strip footnotes (e.g. 7/15a → 7/15)
    line = line.replace(/^(\d{1,2}\/\d{1,2})[a-z]+/i, "$1");

    const parts = line.split(/\s+/);
    const md = parts[0];
    const iso = isoFromMD(md);
    if (!inRange(iso)) continue;

    const driftDel = toNum(parts[1]) ?? 0;
    const setDel   = toNum(parts[2]) ?? 0;
    const sockeye  = toNum(parts[3]) ?? 0;

    map.set(iso, {
      date: iso,
      districtKey: "togiak",   // ✅ FIXED

      // treat delivery days as 24h openings
      driftOpenHours: (driftDel > 0 || setDel > 0) ? 24 : 0,
      setOpenHours:   (driftDel > 0 || setDel > 0) ? 24 : 0,

      driftDeliveries: driftDel,
      setDeliveries: setDel,
      sockeyeDaily: sockeye,

      flags: "table19_togiak",
      notes: "hours_assumed_24_from_delivery_presence",
    });
  }

  return map;
}

/* =========================
   NUSHAGAK – EXPLODED
   ========================= */
function parseNushagakExploded(lines){
  const map = new Map();

  for (let i = 0; i < lines.length; i++){
    const a = (lines[i] ?? "").trim();
    if (!/^\d{1,2}\/\d{1,2}[a-z]?$/i.test(a)) continue;

    const iso = isoFromMD(stripDateFootnote(a));
    if (!inRange(iso)) continue;

    const b = (lines[i+1] ?? "").trim();
    const c = (lines[i+2] ?? "").trim();
    if (!c) continue;

    let driftHours = 0, setHours = 0;

    for (const p of (b + " " + c).split(/\s+/)){
      if (/^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(p)){
        const [l,r] = p.split("/").map(toNum);
        driftHours = Math.max(driftHours, l ?? 0);
        setHours   = Math.max(setHours,   r ?? 0);
      }
    }

    const nums = [];
    for (const p of c.split(/\s+/)){
      if (/^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(p)) continue;
      const n = toNum(p);
      if (n != null) nums.push(n);
    }

    map.set(iso, {
      date: iso,
      districtKey: "nushagak",
      driftOpenHours: driftHours,
      setOpenHours: setHours,
      driftDeliveries: nums[0] ?? 0,
      setDeliveries: nums[1] ?? 0,
      sockeyeDaily: 0,
      flags: "from_exploded_table",
      notes: "",
    });

    i += 2;
  }

  return map;
}

/* =========================
   MAIN
   ========================= */
const out = [];
out.push("date,districtKey,driftOpenHours,setOpenHours,driftDeliveries,setDeliveries,sockeyeDaily,flags,notes");

for (const d of DISTRICTS){
  const lines = readLines(d.file);

  let map;
  if (d.mode === "togiak") map = parseTogiak(lines);
  else if (d.mode === "nushagak_exploded") map = parseNushagakExploded(lines);
  else map = parseStandard(lines, d.key);

  for (const iso of dateRange(START, END)){
    const row = map.get(iso);

    // 🔒 NEVER synthesize Togiak
    if (d.key === "togiak"){
      if (!row) continue;
      out.push(Object.values(row).join(","));
      continue;
    }

    const finalRow = row || {
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

    out.push(Object.values(finalRow).join(","));
  }
}

fs.writeFileSync(OUT_CSV, out.join("\n") + "\n", "utf8");
console.log(`✅ wrote ${OUT_CSV} (${out.length - 1} rows)`);
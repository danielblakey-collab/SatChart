#!/usr/bin/env node
/**
 * Parse district catch tables (ops) from PDF into ops_<year>.csv
 *
 * Usage:
 *   node tmp/parse_ops_from_pdf.js --pdf="src/data/2020/raw/FMR 2020.pdf" --year=2020 --out="src/data/2020/ops_2020.csv"
 */

const fs = require("fs");
const path = require("path");
const pdfjsLib = require("pdfjs-dist/legacy/build/pdf.js"); // <-- added, instead of pulling from pdf_table_utils

function arg(name, def = null) {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`));
  return a ? a.split("=").slice(1).join("=") : def;
}

const PDF_PATH = arg("pdf");
const YEAR = Number(arg("year"));
const OUT = arg("out");
if (!PDF_PATH || !YEAR || !OUT) {
  console.error("Usage: --pdf=... --year=YYYY --out=...");
  process.exit(1);
}

function pad2(n) { return String(n).padStart(2, "0"); }
function isoFromMD(md) {
  const [m, d] = md.split("/").map((x) => Number(String(x).replace(/[^\d]/g, "")));
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}
function toNum(s) {
  if (s == null) return null;
  const t = String(s).trim();
  if (!t || t === "-" || t === "–" || t.toUpperCase() === "ND") return null;
  const n = Number(t.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

function groupByLine(items, yTol = 2.0) {
  const sorted = items.slice().sort((a, b) => a.y - b.y || a.x - b.x);
  const lines = [];
  for (const it of sorted) {
    const last = lines[lines.length - 1];
    if (!last || Math.abs(last.y - it.y) > yTol) lines.push({ y: it.y, items: [it] });
    else last.items.push(it);
  }
  for (const ln of lines) ln.items.sort((a, b) => a.x - b.x);
  return lines;
}

async function pageItems(pdf, pageNum) {
  const page = await pdf.getPage(pageNum);
  const tc = await page.getTextContent();
  return tc.items
    .filter((it) => it.str && it.str.trim())
    .map((it) => ({ str: it.str.trim(), x: it.transform[4], y: it.transform[5] }));
}

function lineText(ln) { return ln.items.map((i) => i.str).join(" "); }

function findLineIndex(lines, predicate, from = 0, to = lines.length) {
  for (let i = from; i < Math.min(lines.length, to); i++) if (predicate(lines[i])) return i;
  return -1;
}

function looksLikeDateToken(s) {
  return /^\d{1,2}\/\d{1,2}/.test(String(s));
}
function stripDateFootnote(s) {
  // "7/17b" or "6/15a,b" -> "7/17" / "6/15"
  return String(s).trim().replace(/^(\d{1,2}\/\d{1,2}).*$/, "$1");
}

function inferColumnBoundsFromHeaderLine(headerLine) {
  // We expect header tokens: Date Drift Set Drift Set Sockeye Chinook Chum Pink Coho Total (some tables omit some species)
  // We build bounds by each token's x.
  const items = headerLine.items;
  const cols = [];
  for (const it of items) {
    const key = it.str.toLowerCase();
    cols.push({ key, x: it.x });
  }
  cols.sort((a, b) => a.x - b.x);

  // turn into bounds between adjacent header x positions
  const bounds = [];
  for (let i = 0; i < cols.length; i++) {
    const left = cols[i].x - 5;
    const right = i < cols.length - 1 ? cols[i + 1].x - 5 : 1e9;
    bounds.push({ key: cols[i].key, left, right });
  }
  return bounds;
}

function pickValueInBounds(line, left, right) {
  const inBand = line.items.filter((it) => it.x >= left && it.x < right);
  if (!inBand.length) return null;
  // Join all tokens in band (handles split numbers)
  const raw = inBand.map((i) => i.str).join("").replace(/\s+/g, "");
  return raw;
}

function parseStandardDistrictTable(lines, titleIdx, districtKey) {
  // Find header row containing Date Drift Set Drift Set Sockeye...
  const headerIdx = findLineIndex(
    lines,
    (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.includes("date") && t.includes("drift") && t.includes("set") && t.includes("sockeye");
    },
    titleIdx,
    titleIdx + 40
  );
  if (headerIdx < 0) return [];

  const bounds = inferColumnBoundsFromHeaderLine(lines[headerIdx]);

  // Helper to find nth occurrence keys (because header has Drift twice, Set twice)
  const driftBands = bounds.filter((b) => b.key === "drift");
  const setBands = bounds.filter((b) => b.key === "set");
  const sockeyeBand = bounds.find((b) => b.key === "sockeye");
  const totalBand = bounds.find((b) => b.key === "total");

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;
    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);

    // hours: first Drift + first Set
    const driftHoursRaw = driftBands[0] ? pickValueInBounds(ln, driftBands[0].left, driftBands[0].right) : null;
    const setHoursRaw = setBands[0] ? pickValueInBounds(ln, setBands[0].left, setBands[0].right) : null;

    // deliveries: second Drift + second Set
    const driftDelRaw = driftBands[1] ? pickValueInBounds(ln, driftBands[1].left, driftBands[1].right) : null;
    const setDelRaw = setBands[1] ? pickValueInBounds(ln, setBands[1].left, setBands[1].right) : null;

    const driftOpenHours = toNum(driftHoursRaw) ?? 0;
    const setOpenHours = toNum(setHoursRaw) ?? 0;

    const driftDeliveries = toNum(driftDelRaw) ?? 0;
    const setDeliveries = toNum(setDelRaw) ?? 0;

    // Sockeye daily: prefer sockeye column; fallback to total column if necessary
    const sockeyeRaw = sockeyeBand ? pickValueInBounds(ln, sockeyeBand.left, sockeyeBand.right) : null;
    const totalRaw = totalBand ? pickValueInBounds(ln, totalBand.left, totalBand.right) : null;

    const sockeye = toNum(sockeyeRaw);
    const total = toNum(totalRaw);

    const sockeyeDaily = sockeye ?? total ?? 0;

    const flags = [];
    const notes = [];

    // Your rule: deliveries can exist while closed; DO NOT auto-open. Only mark open if driftOpenHours > 0.
    // (we still keep deliveries recorded)
    if ((driftDeliveries > 0 || setDeliveries > 0) && (sockeye == null && total == null)) {
      flags.push("sockeye_missing_confidential_or_not_reported");
    }

    out.push({
      date: dateISO,
      districtKey,
      driftOpenHours,
      setOpenHours,
      driftDeliveries,
      setDeliveries,
      sockeyeDaily,
      flags: flags.join("|"),
      notes: notes.join("|"),
    });
  }

  return out;
}

function parseTogiakDeliveriesOnly(lines, titleIdx, districtKey) {
  // Header: Date Drift Set Sockeye ...
  const headerIdx = findLineIndex(
    lines,
    (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.includes("deliveries") && t.includes("date") && t.includes("sockeye");
    },
    titleIdx,
    titleIdx + 40
  );

  // Some PDFs: the header line might just be "Date Drift Set Sockeye..." without "Deliveries"
  const altHeaderIdx = headerIdx >= 0
    ? headerIdx
    : findLineIndex(lines, (ln) => {
        const t = lineText(ln).toLowerCase();
        return t.startsWith("date") && t.includes("drift") && t.includes("set") && t.includes("sockeye");
      }, titleIdx, titleIdx + 40);

  if (altHeaderIdx < 0) return [];

  const bounds = inferColumnBoundsFromHeaderLine(lines[altHeaderIdx]);
  const driftBand = bounds.find((b) => b.key === "drift");
  const setBand = bounds.find((b) => b.key === "set");
  const sockeyeBand = bounds.find((b) => b.key === "sockeye");
  const totalBand = bounds.find((b) => b.key === "total");

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;
    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);

    const driftDeliveries = toNum(driftBand ? pickValueInBounds(ln, driftBand.left, driftBand.right) : null) ?? 0;
    const setDeliveries = toNum(setBand ? pickValueInBounds(ln, setBand.left, setBand.right) : null) ?? 0;

    const sockeye = toNum(sockeyeBand ? pickValueInBounds(ln, sockeyeBand.left, sockeyeBand.right) : null);
    const total = toNum(totalBand ? pickValueInBounds(ln, totalBand.left, totalBand.right) : null);
    const sockeyeDaily = sockeye ?? total ?? 0;

    // Hours are not present -> keep 0 unless driftOpenHours was explicitly in table (it isn't)
    // If you later decide “assume 24 on delivery days”, do it downstream, not here.
    out.push({
      date: dateISO,
      districtKey,
      driftOpenHours: 0,
      setOpenHours: 0,
      driftDeliveries: driftDeliveries,
      setDeliveries: setDeliveries,
      sockeyeDaily,
      flags: "hours_not_reported_in_delivery_table",
      notes: "",
    });
  }

  return out;
}

function parseNushagakHoursSlash(lines, titleIdx, districtKey) {
  // Nushagak tables have hours like "13.5/24" for Nushagak and Igushik.
  // We’ll parse driftOpenHours = max(left sides), setOpenHours = max(right sides),
  // then driftDeliveries + setDeliveries, then sockeye.
  const headerIdx = findLineIndex(
    lines,
    (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.includes("hours fished") && t.includes("deliveries") && t.includes("sockeye");
    },
    titleIdx,
    titleIdx + 60
  );
  if (headerIdx < 0) {
    // fallback: look for "date nushagak igushik drift set sockeye"
    const alt = findLineIndex(lines, (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.startsWith("date") && t.includes("nushagak") && t.includes("igushik") && t.includes("sockeye");
    }, titleIdx, titleIdx + 80);
    if (alt < 0) return [];
  }

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;

    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);

    const tokens = ln.items.map((i) => i.str);

    // Find all tokens matching \d+/\d+
    const frac = tokens.filter((t) => /^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(t));
    const h1 = frac[0] ?? "0/0";
       const h2 = frac[1] ?? "0/0";
    const [d1, s1] = h1.split("/").map(toNum);
    const [d2, s2] = h2.split("/").map(toNum);

    const driftOpenHours = Math.max(d1 ?? 0, d2 ?? 0);
    const setOpenHours = Math.max(s1 ?? 0, s2 ?? 0);

    // Collect numeric tokens after removing date + frac tokens
    const nums = [];
    for (const t of tokens.slice(1)) {
      if (/^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(t)) continue;
      const n = toNum(t);
      if (n != null) nums.push(n);
    }

    const driftDeliveries = nums[0] ?? 0;
    const setDeliveries = nums[1] ?? 0;
    const sockeye = nums[2] ?? null;
    const sockeyeDaily = sockeye ?? 0;

    // Your rule: if driftOpenHours is 0/0 and there are deliveries, treat as closed.
    // This applies to all districts, but Nushagak is where it happens most.
    // We preserve deliveries but do not mark open.
    out.push({
      date: dateISO,
      districtKey,
      driftOpenHours: driftOpenHours,
      setOpenHours: setOpenHours,
      driftDeliveries,
      setDeliveries,
      sockeyeDaily,
      flags: "nushagak_hours_slash_format",
      notes: "",
    });
  }

  return out;
}

const OPS_TABLES = [
  { districtKey: "naknek-kvichak", titleNeedle: "naknek-kvichak district" },
  { districtKey: "egegik", titleNeedle: "egegik district" },
  { districtKey: "ugashik", titleNeedle: "ugashik district" },
  { districtKey: "nushagak", titleNeedle: "nushagak district" },
  { districtKey: "togiak", titleNeedle: "togiak district" },
];

(async () => {
  const data = new Uint8Array(fs.readFileSync(PDF_PATH));
  const pdf = await pdfjsLib.getDocument({ data }).promise;

  const rows = [];

  for (let p = 1; p <= pdf.numPages; p++) {
    const items = await pageItems(pdf, p);
    const lines = groupByLine(items);

    for (const t of OPS_TABLES) {
      const idx = findLineIndex(lines, (ln) => lineText(ln).toLowerCase().includes(t.titleNeedle));
      if (idx < 0) continue;

      if (t.districtKey === "togiak") {
        rows.push(...parseTogiakDeliveriesOnly(lines, idx, t.districtKey));
      } else if (t.districtKey === "nushagak") {
        rows.push(...parseNushagakHoursSlash(lines, idx, t.districtKey));
      } else {
        rows.push(...parseStandardDistrictTable(lines, idx, t.districtKey));
      }
    }
  }

  // Dedup (date,district) last-write-wins
  const byKey = new Map();
  for (const r of rows) byKey.set(`${r.date}__${r.districtKey}`, r);

  const final = Array.from(byKey.values()).sort((a, b) =>
    a.date.localeCompare(b.date) || a.districtKey.localeCompare(b.districtKey)
  );

  const header =
    "date,districtKey,driftOpenHours,setOpenHours,driftDeliveries,setDeliveries,sockeyeDaily,flags,notes\n";

  const csv =
    header +
    final
      .map((r) =>
        [
          r.date,
          r.districtKey,
          r.driftOpenHours ?? 0,
          r.setOpenHours ?? 0,
          r.driftDeliveries ?? 0,
          r.setDeliveries ?? 0,
          r.sockeyeDaily ?? 0,
          r.flags ?? "",
          r.notes ?? "",
        ].join(",")
      )
      .join("\n") +
    "\n";

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, csv, "utf8");
  console.log(`✅ wrote ${OUT} (${final.length} rows)`);
})();
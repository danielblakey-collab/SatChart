#!/usr/bin/env node
/**
 * tmp/parse_rivers_from_pdf_ocr.js
 *
 * OCR-based parsing for rivers tables:
 * - Eastside tower: Kvichak, Naknek, Alagnak, Egegik, Ugashik
 * - Westside tower: Wood, Igushik, Togiak
 * - Nushagak sonar: sockeye only (riverKey=nushagak, method=sonar)
 *
 * Output CSV:
 * date,riverKey,method,isOperational,dailyEscapement,cumulativeEscapement,flags,notes
 *
 * Usage:
 * node tmp/parse_rivers_from_pdf_ocr.js --pdf="path/to/FMR_2020.pdf" --year=2020 --out="src/data/2020/rivers_2020.csv"
 * optional: --pages=41,58,59,38  (if you already know the pages)
 */

const fs = require("fs");
const path = require("path");
const {
  arg, loadPdf, renderPageToPng, ocrTsv, parseTsv, groupByLine,
  norm, looksLikeDate, toNumberToken, pad2
} = require("./pdf_ocr_utils");

const PDF_PATH = arg("pdf");
const YEAR = Number(arg("year"));
const OUT = arg("out");
const PAGES = arg("pages"); // optional comma list

if (!PDF_PATH || !YEAR || !OUT) {
  console.error('Usage: --pdf="..." --year=YYYY --out="..." [--pages=..]');
  process.exit(1);
}

function isoFromMD(md) {
  const clean = String(md).replace(/[^0-9/]/g, "");
  const [m, d] = clean.split("/").map(Number);
  if (!m || !d) return null;
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}

function writeCsv(rows) {
  const header = "date,riverKey,method,isOperational,dailyEscapement,cumulativeEscapement,flags,notes\n";
  const csv =
    header +
    rows
      .map((r) =>
        [
          r.date,
          r.riverKey,
          r.method,
          r.isOperational ? "true" : "false",
          r.dailyEscapement ?? "",
          r.cumulativeEscapement ?? "",
          r.flags ?? "",
          r.notes ?? "",
        ].join(",")
      )
      .join("\n") +
    "\n";
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, csv, "utf8");
}

function findBestPageHits(lines, needleWords) {
  // heuristic: count needle matches across page
  const text = norm(lines.map((ln) => ln.words.map((w) => w.text).join(" ")).join(" "));
  let hits = 0;
  for (const n of needleWords) if (text.includes(n)) hits++;
  return hits;
}

function inferRiverAnchors(lines, riverKeys) {
  // find x positions of each river label by scanning all lines
  const anchors = {};
  for (const ln of lines) {
    for (const w of ln.words) {
      const t = norm(w.text);
      for (const rk of riverKeys) {
        if (t === rk || t === rk + "river" || t.startsWith(rk)) {
          anchors[rk] = anchors[rk] ?? w.left;
          anchors[rk] = Math.min(anchors[rk], w.left);
        }
      }
    }
  }
  const found = Object.keys(anchors);
  if (found.length < Math.max(2, Math.floor(riverKeys.length * 0.6))) {
    return null;
  }
  const ordered = found.sort((a, b) => anchors[a] - anchors[b]);
  const bounds = [];
  for (let i = 0; i < ordered.length; i++) {
    const left = anchors[ordered[i]] - 20;
    const right = i < ordered.length - 1 ? anchors[ordered[i + 1]] - 20 : 1e9;
    bounds.push({ riverKey: ordered[i], left, right });
  }
  return bounds;
}

function inferDailyCumSplit(lines, bounds) {
  // find a line containing "date daily cum" or at least daily/cum tokens
  let sub = null;
  for (const ln of lines) {
    const t = norm(ln.words.map((w) => w.text).join(" "));
    if (t.includes("date") && t.includes("daily") && (t.includes("cum") || t.includes("cum."))) {
      sub = ln;
      break;
    }
  }
  // if missing, fallback to splitting each river col mid
  const splits = {};
  for (const b of bounds) {
    if (!sub) {
      splits[b.riverKey] = (b.left + b.right) / 2;
      continue;
    }
    const within = sub.words.filter((w) => w.left >= b.left && w.left < b.right);
    const cum = within.find((w) => norm(w.text).startsWith("cum"));
    if (cum) splits[b.riverKey] = cum.left - 5;
    else splits[b.riverKey] = (b.left + b.right) / 2;
  }
  return splits;
}

function parseTower(lines, riverKeys, noteTag) {
  const bounds = inferRiverAnchors(lines, riverKeys);
  if (!bounds) return [];

  const splits = inferDailyCumSplit(lines, bounds);

  // find data lines by date token at left-ish
  const out = [];
  for (const ln of lines) {
    const dateWord = ln.words.find((w) => looksLikeDate(w.text));
    if (!dateWord) continue;

    const dateISO = isoFromMD(dateWord.text);
    if (!dateISO) continue;

    for (const b of bounds) {
      const splitX = splits[b.riverKey];
      const inCol = ln.words.filter((w) => w.left >= b.left && w.left < b.right);

      const dailyNums = inCol
        .filter((w) => w.left < splitX)
        .map((w) => toNumberToken(w.text))
        .filter((n) => n != null);

      const cumNums = inCol
        .filter((w) => w.left >= splitX)
        .map((w) => toNumberToken(w.text))
        .filter((n) => n != null);

      const daily = dailyNums.length ? dailyNums[0] : null;
      const cum = cumNums.length ? cumNums[0] : null;

      out.push({
        date: dateISO,
        riverKey: b.riverKey,
        method: "tower",
        isOperational: daily != null || cum != null,
        dailyEscapement: daily,
        cumulativeEscapement: cum,
        flags: "",
        notes: noteTag,
      });
    }
  }
  return out;
}

function parseNushagakSonar(lines) {
  // Table with Date + Sockeye daily/cum + other species. We only emit sockeye.
  const out = [];
  for (const ln of lines) {
    const dateWord = ln.words.find((w) => looksLikeDate(w.text));
    if (!dateWord) continue;

    const dateISO = isoFromMD(dateWord.text);
    if (!dateISO) continue;

    // numbers to the right of date, in x order
    const right = ln.words.filter((w) => w.left > dateWord.left + 5).sort((a, b) => a.left - b.left);
    const nums = right.map((w) => toNumberToken(w.text)).filter((n) => n != null);
    if (nums.length < 2) continue;

    out.push({
      date: dateISO,
      riverKey: "nushagak",
      method: "sonar",
      isOperational: true,
      dailyEscapement: nums[0],
      cumulativeEscapement: nums[1],
      flags: "",
      notes: "sonar_sockeye_only",
    });
  }
  return out;
}

(async () => {
  const pdf = await loadPdf(PDF_PATH);
  const tmpDir = path.join("tmp", "ocr_pages", String(YEAR));
  fs.mkdirSync(tmpDir, { recursive: true });

  const wantPages = PAGES ? PAGES.split(",").map((x) => Number(x.trim())).filter(Boolean) : null;

  const rows = [];
  const seen = new Map();

  for (let p = 1; p <= pdf.numPages; p++) {
    if (wantPages && !wantPages.includes(p)) continue;

    const png = path.join(tmpDir, `p${String(p).padStart(3, "0")}.png`);
    await renderPageToPng(pdf, p, png, 3.0);

    const tsv = await ocrTsv(png);
    const words = parseTsv(tsv);
    if (!words.length) continue;

    const lines = groupByLine(words, 12);

    // classify page by keyword hits
    const textAll = norm(lines.map((ln) => ln.words.map((w) => w.text).join(" ")).join(" "));
    const isEast = textAll.includes("eastside") || textAll.includes("kvichak") || textAll.includes("alagnak");
    const isWest = textAll.includes("westside") || textAll.includes("wood") || textAll.includes("igushik");
    const isSonar = textAll.includes("nushagak") && textAll.includes("sonar");

    let newRows = [];
    if (isEast) newRows = parseTower(lines, ["kvichak", "naknek", "alagnak", "egegik", "ugashik"], `pdf_p${p}_eastside`);
    else if (isWest) newRows = parseTower(lines, ["wood", "igushik", "togiak"], `pdf_p${p}_westside`);
    else if (isSonar) newRows = parseNushagakSonar(lines);

    for (const r of newRows) {
      const k = `${r.date}__${r.riverKey}__${r.method}`;
      // keep the latest non-null record if duplicates occur
      const prev = seen.get(k);
      if (!prev) seen.set(k, r);
      else {
        const prevScore = (prev.dailyEscapement != null) + (prev.cumulativeEscapement != null);
        const curScore = (r.dailyEscapement != null) + (r.cumulativeEscapement != null);
        if (curScore >= prevScore) seen.set(k, r);
      }
    }
  }

  const final = Array.from(seen.values()).sort(
    (a, b) => a.date.localeCompare(b.date) || a.riverKey.localeCompare(b.riverKey) || a.method.localeCompare(b.method)
  );

  writeCsv(final);
  console.log(`✅ wrote ${OUT} (${final.length} rows)`);
})().catch((e) => {
  console.error("FAILED:", e);
  process.exit(1);
});

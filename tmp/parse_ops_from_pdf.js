#!/usr/bin/env node
/**
 * Parse district catch tables (ops) from PDF into ops_<year>.csv
 *
 * Usage:
 *   node tmp/parse_ops_from_pdf.js \
 *     --pdf="src/data/2020/raw/FMR_2020.pdf" \
 *     --year=2020 \
 *     --out="src/data/2020/ops_2020.csv" \
 *     --verbose
 */

const fs = require("fs");
const path = require("path");
const { loadPdf } = require("./pdf_table_utils");

/* -----------------------
 * CLI args
 * ----------------------- */

function arg(name, def = null) {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`));
  return a ? a.split("=").slice(1).join("=") : def;
}

const PDF_PATH = arg("pdf");
const YEAR = Number(arg("year"));
const OUT = arg("out");
const VERBOSE = process.argv.includes("--verbose");

if (!PDF_PATH || !YEAR || !OUT) {
  console.error("Usage: --pdf=... --year=YYYY --out=... [--verbose]");
  process.exit(1);
}

/* -----------------------
 * Helpers
 * ----------------------- */

function pad2(n) {
  return String(n).padStart(2, "0");
}

function isoFromMD(md) {
  const [m, d] = md.split("/").map((x) => Number(String(x).replace(/[^\d]/g, "")));
  if (!m || !d) return null;
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
    if (!last || Math.abs(last.y - it.y) > yTol) {
      lines.push({ y: it.y, items: [it] });
    } else {
      last.items.push(it);
    }
  }
  for (const ln of lines) ln.items.sort((a, b) => a.x - b.x);
  return lines;
}

async function pageItems(pdf, pageNum) {
  const page = await pdf.getPage(pageNum);
  const tc = await page.getTextContent();
  return tc.items
    .filter((it) => it.str && it.str.trim())
    .map((it) => ({
      str: it.str.trim(),
      x: it.transform[4],
      y: it.transform[5],
    }));
}

function lineText(ln) {
  return ln.items.map((i) => i.str).join(" ");
}

function findLineIndex(lines, predicate, from = 0, to = lines.length) {
  for (let i = from; i < Math.min(lines.length, to); i++) {
    if (predicate(lines[i])) return i;
  }
  return -1;
}

function looksLikeDateToken(s) {
  return /^\d{1,2}\/\d{1,2}/.test(String(s));
}

function stripDateFootnote(s) {
  // "7/17b" or "6/15a,b" -> "7/17" / "6/15"
  return String(s).trim().replace(/^(\d{1,2}\/\d{1,2}).*$/, "$1");
}

/**
 * Infer column bounds from a header line.
 *
 * We keep it generic: each header token (lowercased) defines a band.
 * Later we interpret bands by matching `key` strings, not by position.
 */
function inferColumnBoundsFromHeaderLine(headerLine) {
  const items = headerLine.items;
  const cols = [];
  for (const it of items) {
    const key = it.str.toLowerCase();
    cols.push({ key, x: it.x });
  }
  cols.sort((a, b) => a.x - b.x);

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
  const raw = inBand
    .map((i) => i.str)
    .join("")
    .replace(/\s+/g, "");
  return raw;
}

/* -----------------------
 * Title matching
 * ----------------------- */

/**
 * Looser title matching for 2015+ ops tables.
 * We ignore hyphen vs en-dash, and require some "ops" words so we don't
 * accidentally grab escapement/sonar tables.
 */
function isOpsTitleLine(txt, districtKey) {
  const t = txt.toLowerCase();

  // Something that looks like a catch/ops table
  const core =
    t.includes("daily catch") ||
    t.includes("catch by district") ||
    t.includes("hours fished") ||
    t.includes("deliveries") ||
    // 2015 style: "Commercial salmon catch by date and species..., <District> District"
    (t.includes("commercial salmon catch") && t.includes("district"));

  if (!core) return false;

  switch (districtKey) {
    case "naknek-kvichak":
      return t.includes("naknek") && t.includes("kvichak") && t.includes("district");
    case "egegik":
      return t.includes("egegik") && t.includes("district");
    case "ugashik":
      return t.includes("ugashik") && t.includes("district");
    case "nushagak":
      return t.includes("nushagak") && t.includes("district");
    case "togiak":
      return t.includes("togiak") && t.includes("district");
    default:
      return false;
  }
}

/* -----------------------
 * Parsers
 * ----------------------- */

function parseStandardDistrictTable(lines, titleIdx, districtKey) {
  // 2015 ops tables (esp. Naknek–Kvichak) often split the header across
  // two lines: one with "Date Drift Set Drift Set" and a following line
  // with "Sockeye Chinook Chum Pink Coho Total".
  //
  // So we:
  //   1) Find a "core" header line: date + drift + set.
  //   2) If that line doesn't contain any species / catch words,
  //      we merge it with the *next* line and treat the merged line
  //      as the header for column-bound inference.

  const corePredicate = (ln) => {
    const t = lineText(ln).toLowerCase();
    return t.includes("date") && t.includes("drift") && t.includes("set");
  };

  // 1) First try near the title
  let coreIdx = findLineIndex(
    lines,
    corePredicate,
    Math.max(0, titleIdx - 10),
    Math.min(lines.length, titleIdx + 80)
  );

  // 2) Fallback: search the whole page if we didn't find anything nearby
  if (coreIdx < 0) {
    coreIdx = findLineIndex(lines, corePredicate, 0, lines.length);
  }

  if (coreIdx < 0) {
    if (VERBOSE) {
      console.warn(
        `  ⚠️  No core header row (date+drift+set) found for ${districtKey} near title index ${titleIdx}`
      );
    }
    return [];
  }

  const coreLine = lines[coreIdx];
  const coreText = lineText(coreLine).toLowerCase();

  const hasCatchishOnCore =
    coreText.includes("sockeye") ||
    coreText.includes("chinook") ||
    coreText.includes("chum") ||
    coreText.includes("pink") ||
    coreText.includes("coho") ||
    coreText.includes("total") ||
    coreText.includes("salmon") ||
    coreText.includes("catch");

  // Build the actual header line (possibly merged with the next line)
  let headerLine = coreLine;
  if (!hasCatchishOnCore && coreIdx + 1 < lines.length) {
    const nextLine = lines[coreIdx + 1];
    const mergedItems = coreLine.items.concat(nextLine.items);
    headerLine = { y: coreLine.y, items: mergedItems };

    if (VERBOSE) {
      console.log(
        `  • Merged two-line header for ${districtKey} at lines ${coreIdx} and ${
          coreIdx + 1
        }`
      );
    }
  } else if (VERBOSE) {
    console.log(`  • Using single-line header for ${districtKey} at line ${coreIdx}`);
  }

  const bounds = inferColumnBoundsFromHeaderLine(headerLine);

  // header text is generic ("drift", "set", etc.) and appears multiple times;
  // band 0 = hours, band 1 = deliveries
  const driftBands = bounds.filter((b) => b.key.includes("drift"));
  const setBands = bounds.filter((b) => b.key.includes("set"));

  // species / catch columns
  const sockeyeBand = bounds.find(
    (b) =>
      b.key.includes("sockeye") ||
      b.key.includes("red") ||
      (b.key.includes("salmon") && b.key.includes("sockeye"))
  );
  const totalBand = bounds.find(
    (b) =>
      b.key === "total" ||
      b.key.includes("total catch") ||
      b.key.includes("all species")
  );

  if (VERBOSE) {
    console.log(`  • Using standard parser for ${districtKey} (header at line ${coreIdx})`);
  }

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;

    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);
    if (!dateISO) continue;

    const driftHoursRaw =
      driftBands[0] && pickValueInBounds(ln, driftBands[0].left, driftBands[0].right);
    const setHoursRaw =
      setBands[0] && pickValueInBounds(ln, setBands[0].left, setBands[0].right);

    const driftDelRaw =
      driftBands[1] && pickValueInBounds(ln, driftBands[1].left, driftBands[1].right);
    const setDelRaw =
      setBands[1] && pickValueInBounds(ln, setBands[1].left, setBands[1].right);

    const driftOpenHours = toNum(driftHoursRaw) ?? 0;
    const setOpenHours = toNum(setHoursRaw) ?? 0;
    const driftDeliveries = toNum(driftDelRaw) ?? 0;
    const setDeliveries = toNum(setDelRaw) ?? 0;

    const sockeyeRaw =
      sockeyeBand && pickValueInBounds(ln, sockeyeBand.left, sockeyeBand.right);
    const totalRaw =
      totalBand && pickValueInBounds(ln, totalBand.left, totalBand.right);

    const sockeye = toNum(sockeyeRaw);
    const total = toNum(totalRaw);
    const sockeyeDaily = sockeye ?? total ?? 0;

    const flags = [];

    // Deliveries while sockeye column is blank ⇒ note it, but do NOT invent sockeye
    if ((driftDeliveries > 0 || setDeliveries > 0) && sockeye == null && total == null) {
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
      notes: "",
    });
  }

  return out;
}

function parseTogiakDeliveriesOnly(lines, titleIdx, districtKey) {
  const headerIdx = findLineIndex(
    lines,
    (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.includes("deliveries") && t.includes("date") && t.includes("sockeye");
    },
    titleIdx,
    titleIdx + 40
  );

  const altHeaderIdx =
    headerIdx >= 0
      ? headerIdx
      : findLineIndex(
          lines,
          (ln) => {
            const t = lineText(ln).toLowerCase();
            return (
              t.startsWith("date") &&
              t.includes("drift") &&
              t.includes("set") &&
              t.includes("sockeye")
            );
          },
          titleIdx,
          titleIdx + 40
        );

  if (altHeaderIdx < 0) {
    if (VERBOSE) {
      console.warn(`  ⚠️  No Togiak header found near line ${titleIdx}`);
    }
    return [];
  }

  const bounds = inferColumnBoundsFromHeaderLine(lines[altHeaderIdx]);
  const driftBand = bounds.find((b) => b.key.includes("drift"));
  const setBand = bounds.find((b) => b.key.includes("set"));
  const sockeyeBand = bounds.find((b) => b.key.includes("sockeye"));
  const totalBand = bounds.find((b) => b.key === "total" || b.key.includes("total catch"));

  if (VERBOSE) {
    console.log(`  • Using Togiak-deliveries parser (header at line ${altHeaderIdx})`);
  }

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;

    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);
    if (!dateISO) continue;

    const driftDeliveries =
      toNum(driftBand ? pickValueInBounds(ln, driftBand.left, driftBand.right) : null) ??
      0;
    const setDeliveries =
      toNum(setBand ? pickValueInBounds(ln, setBand.left, setBand.right) : null) ?? 0;

    const sockeye = toNum(
      sockeyeBand ? pickValueInBounds(ln, sockeyeBand.left, sockeyeBand.right) : null
    );
    const total = toNum(
      totalBand ? pickValueInBounds(ln, totalBand.left, totalBand.right) : null
    );
    const sockeyeDaily = sockeye ?? total ?? 0;

    out.push({
      date: dateISO,
      districtKey,
      driftOpenHours: 0,
      setOpenHours: 0,
      driftDeliveries,
      setDeliveries,
      sockeyeDaily,
      flags: "hours_not_reported_in_delivery_table",
      notes: "",
    });
  }

  return out;
}

function parseNushagakHoursSlash(lines, titleIdx, districtKey) {
  const headerIdx = findLineIndex(
    lines,
    (ln) => {
      const t = lineText(ln).toLowerCase();
      return t.includes("hours fished") && t.includes("deliveries") && t.includes("sockeye");
    },
    titleIdx,
    titleIdx + 60
  );

  const baseIdx =
    headerIdx >= 0
      ? headerIdx
      : findLineIndex(
          lines,
          (ln) => {
            const t = lineText(ln).toLowerCase();
            return (
              t.startsWith("date") &&
              t.includes("nushagak") &&
              t.includes("igushik") &&
              t.includes("sockeye")
            );
          },
          titleIdx,
          titleIdx + 80
        );

  if (baseIdx < 0) {
    if (VERBOSE) {
      console.warn(`  ⚠️  No Nushagak header found near line ${titleIdx}`);
    }
    return [];
  }

  if (VERBOSE) {
    console.log(`  • Using Nushagak-slash-hours parser (header at line ${baseIdx})`);
  }

  const out = [];

  for (const ln of lines) {
    const first = ln.items[0]?.str ?? "";
    if (!looksLikeDateToken(first)) continue;

    const md = stripDateFootnote(first);
    const dateISO = isoFromMD(md);
    if (!dateISO) continue;

    const tokens = ln.items.map((i) => i.str);

    const frac = tokens.filter((t) => /^\d+(\.\d+)?\/\d+(\.\d+)?$/.test(t));
    const h1 = frac[0] ?? "0/0";
    const h2 = frac[1] ?? "0/0";
    const [d1, s1] = h1.split("/").map(toNum);
    const [d2, s2] = h2.split("/").map(toNum);

    const driftOpenHours = Math.max(d1 ?? 0, d2 ?? 0);
    const setOpenHours = Math.max(s1 ?? 0, s2 ?? 0);

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

    out.push({
      date: dateISO,
      districtKey,
      driftOpenHours,
      setOpenHours,
      driftDeliveries,
      setDeliveries,
      sockeyeDaily,
      flags: "nushagak_hours_slash_format",
      notes: "",
    });
  }

  return out;
}

/* -----------------------
 * Main
 * ----------------------- */

const OPS_TABLES = [
  { districtKey: "naknek-kvichak" },
  { districtKey: "egegik" },
  { districtKey: "ugashik" },
  { districtKey: "nushagak" },
  { districtKey: "togiak" },
];

(async () => {
  const pdf = await loadPdf(PDF_PATH);
  const rows = [];

  for (let p = 1; p <= pdf.numPages; p++) {
    const items = await pageItems(pdf, p);
    const lines = groupByLine(items);

    if (VERBOSE) {
      console.log(`Scanning page ${p} for ops tables...`);
    }

    for (const t of OPS_TABLES) {
      const titleIdx = findLineIndex(lines, (ln) =>
        isOpsTitleLine(lineText(ln), t.districtKey)
      );
      if (titleIdx < 0) continue;

      if (VERBOSE) {
        console.log(`- Found ${t.districtKey} ops title on page ${p}, line ${titleIdx}`);
      }

      if (t.districtKey === "togiak") {
        rows.push(...parseTogiakDeliveriesOnly(lines, titleIdx, t.districtKey));
      } else if (t.districtKey === "nushagak") {
        rows.push(...parseNushagakHoursSlash(lines, titleIdx, t.districtKey));
      } else {
        rows.push(...parseStandardDistrictTable(lines, titleIdx, t.districtKey));
      }
    }
  }

  const byKey = new Map();
  for (const r of rows) {
    byKey.set(`${r.date}__${r.districtKey}`, r);
  }

  const final = Array.from(byKey.values()).sort(
    (a, b) => a.date.localeCompare(b.date) || a.districtKey.localeCompare(b.districtKey)
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
})().catch((err) => {
  console.error("FAILED:", err);
  process.exit(1);
});
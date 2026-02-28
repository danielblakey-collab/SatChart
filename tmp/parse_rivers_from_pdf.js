#!/usr/bin/env node
/**
 * parse_rivers_from_pdf.js
 *
 * Robust rivers parser:
 * - Eastside tower (Kvichak, Naknek, Alagnak, Egegik, Ugashik)
 * - Westside tower (Wood, Igushik, Togiak)
 * - Nushagak sonar sockeye (riverKey=nushagak, method=sonar)
 *
 * Key guarantees:
 * - Tower rows: isOperational=true ONLY if BOTH daily and cumulative are parsed.
 * - Eastside tower: column mapping is locked from a single fully-populated calibration row (pref 7/10)
 *   on the EASTSIDE header page, then applied to ALL eastside rows (including earlier dates).
 * - Eastside hard rule: NO operational row with only daily (or only cumulative). Missing either => tower,false.
 * - Pre-start rule (eastside): for each river, all dates BEFORE first day where daily==cumulative>0 are tower,false.
 * - Westside + sonar assume 2 pages (header + next page) and reuse geometry from page 1.
 *
 * Usage:
 *   node tmp/parse_rivers_from_pdf.js --pdf="src/data/2020/raw/FMR_2020.pdf" --year=2020 --out="src/data/2020/rivers_2020.csv" [--verbose]
 */

const fs = require("fs");
const { loadPdf, pageItemsSmart, groupByLine, normalize } = require("./pdf_table_utils");

function arg(name, def = null) {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`));
  return a ? a.split("=").slice(1).join("=") : def;
}

const PDF_PATH = arg("pdf");
const YEAR = Number(arg("year"));
const OUT = arg("out");
const VERBOSE = process.argv.includes("--verbose");

if (!PDF_PATH || !YEAR || !OUT) {
  console.error('Usage: node tmp/parse_rivers_from_pdf.js --pdf="..." --year=YYYY --out="..." [--verbose]');
  process.exit(1);
}

const pad2 = (n) => String(n).padStart(2, "0");

function findFirstLineIndex(lines, predicate) {
  for (let i = 0; i < (lines?.length ?? 0); i++) {
    if (predicate(lines[i], i)) return i;
  }
  return -1;
}

function looksLikeDateToken(raw) {
  const s = String(raw ?? "").trim();
  // allow OCR variants: 7/7, 7|7, 7/7a, trailing punctuation
  return /^\d{1,2}[\/|]\d{1,2}[a-z]?[.,]?$/.test(s);
}

function normalizeDateToken(raw) {
  return String(raw ?? "")
    .trim()
    .replaceAll("|", "/")
    .replace(/[.,]$/g, "");
}

function isoFromMD(raw, year = YEAR) {
  const clean = normalizeDateToken(raw).replace(/[^\d/]/g, "");
  const [m, d] = clean.split("/").map(Number);
  if (!m || !d) return null;
  return `${year}-${pad2(m)}-${pad2(d)}`;
}

function looksLikeOpeningSchedule(big) {
  if (big.includes("akn.")) return true;
  if (big.includes("opening schedule")) return true;
  if (big.includes("commercial") && big.includes("opening")) return true;
  const timeLike = (big.match(/\b\d{1,2}:\d{2}\b/g) || []).length;
  if (timeLike >= 4) return true;
  const hoursLike = (big.match(/\bhours?\b/g) || []).length;
  if (hoursLike >= 3 && timeLike >= 2) return true;
  return false;
}

function isNumericFragment(raw) {
  const t = String(raw ?? "").trim();
  if (!t) return false;
  if (t === "-" || t === "–" || t.toUpperCase() === "ND") return false;
  return /^\d+$/.test(t) || /^\d{1,3}(?:[,.]\d{3})+$/.test(t);
}

function toNumSafe(raw) {
  const t = String(raw ?? "").trim();
  if (!t || t === "-" || t === "–" || t.toUpperCase() === "ND") return null;
  const cleaned = t.replace(/[,.](?=\d{3}\b)/g, "");
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function mergeSplitNumbersRow(itemsInRow) {
  const items = (itemsInRow || [])
    .filter((it) => it && it.str && String(it.str).trim())
    .slice()
    .sort((a, b) => a.x - b.x);

  const out = [];
  for (const it of items) {
    const s = String(it.str).trim();
    if (!isNumericFragment(s)) {
      out.push({ ...it, _numMerge: false });
      continue;
    }
    const last = out[out.length - 1];
    if (last && last._numMerge && isNumericFragment(last.str)) {
      const lastRight =
        typeof last.w === "number"
          ? last.x + last.w
          : last.x + Math.max(8, String(last.str).length * 6);
      const gap = it.x - lastRight;
      if (gap >= -2 && gap <= 10) {
        last.str = String(last.str) + s;
        last._numMerge = true;
        if (typeof last.w === "number" && typeof it.w === "number") {
          const newRight = it.x + it.w;
          last.w = Math.max(last.w, newRight - last.x);
        }
        continue;
      }
    }
    out.push({ ...it, _numMerge: true });
  }
  return out;
}

const EAST_RIVERS = ["kvichak", "naknek", "alagnak", "egegik", "ugashik"]; // fixed order

function getActiveEastRivers() {
  // Before 2017, Alagnak escapement is not in the eastside tower table;
  // it is estimated elsewhere. For those years, drop it from the tower parser.
  if (YEAR <= 2016) {
    return EAST_RIVERS.filter((rk) => rk !== "alagnak");
  }
  return EAST_RIVERS.slice();
}

const EAST_START_MMDD_BY_YEAR = {
  2014: {
    kvichak: "06-16",
    naknek: "06-14",
    alagnak: "06-25",
    egegik: "06-13",
    ugashik: "06-27",
  },
  2015: {
    kvichak: "06-16",
    naknek: "06-14",
    alagnak: "06-25",
    egegik: "06-11",
    ugashik: "06-26",
  },
  2016: {
    kvichak: "06-16",
    naknek: "06-14",
    alagnak: "06-30",
    egegik: "06-12",
    ugashik: "06-26",
  },
  2017: {
    kvichak: "06-22",
    naknek: "06-19",
    alagnak: "06-28",
    egegik: "06-18",
    ugashik: "06-27",
  },
  2018: {
    kvichak: "06-22",
    naknek: "06-20",
    alagnak: "06-29",
    egegik: "06-17",
    ugashik: "06-27",
  },
  2019: {
    kvichak: "06-22", // first *real* Kvichak day you trust
    naknek: "06-21",  // first *real* Naknek day you trust
    alagnak: "06-25",
    egegik: "06-17",
    ugashik: "06-27",
  },
  2020: {
    kvichak: "06-22",
    naknek: "06-19",
    alagnak: "06-30",
    egegik: "06-18",
    ugashik: "06-27",
  },
  2021: {
    kvichak: "06-23",
    naknek: "06-19",
    alagnak: "06-29",
    egegik: "06-17",
    ugashik: "06-29",
  },
  2022: {
    kvichak: "06-23",
    naknek: "06-20",
    alagnak: "06-29",
    egegik: "06-17",
    ugashik: "06-27",
  },
  2023: {
    kvichak: "06-24",
    naknek: "06-21",
    alagnak: "07-01",
    egegik: "06-17",
    ugashik: "06-28",
  },
  2024: {
    kvichak: "06-22", // 72/72
    naknek: "06-21",  // 48/48
    alagnak: "07-01",
    egegik: "06-17",
    ugashik: "06-27",
  },
};

let KVICHIK_DEBUG_PRINTED = false;
function findLineByMMDD(lines, mmdd) {
  const want = mmdd.replace(/^0/, "");
  return lines.find((ln) =>
    ln.items.some((it) => {
      if (!looksLikeDateToken(it.str)) return false;
      return normalizeDateToken(it.str).startsWith(want);
    })
  );
}


function getMergedNumericTokensAfterDate(lineItems, dateX) {
  const merged = mergeSplitNumbersRow(lineItems);
  return merged
    .filter((it) => it.x > dateX + 2)
    .filter((it) => isNumericFragment(it.str))
    .map((it) => ({ x: it.x, n: toNumSafe(it.str), raw: String(it.str) }))
    .filter((o) => o.n != null)
    .sort((a, b) => a.x - b.x);
}

function getMergedNumericTokensInRow(lineItems) {
  const merged = mergeSplitNumbersRow(lineItems);
  return merged
    .filter((it) => isNumericFragment(it.str))
    .map((it) => ({ x: it.x, n: toNumSafe(it.str), raw: String(it.str) }))
    .filter((o) => o.n != null)
    .sort((a, b) => a.x - b.x);
}

function buildEastsideCentersFrom0710(eastHeaderLines) {
  const activeEast = getActiveEastRivers();

  const calLine =
    findLineByMMDD(eastHeaderLines, "7/10") ||
    findLineByMMDD(eastHeaderLines, "7/11") ||
    findLineByMMDD(eastHeaderLines, "7/9");
  if (!calLine) {
    throw new Error("eastside: could not find calibration row (prefer 7/10) on header page");
  }

  const dateIt = calLine.items.find((it) => looksLikeDateToken(it.str));
  if (!dateIt) {
    throw new Error("eastside: calibration row missing date token");
  }

  const nums = getMergedNumericTokensAfterDate(calLine.items, dateIt.x);
  const expectedCols = activeEast.length * 2;
  if (nums.length < expectedCols) {
    throw new Error(
      `eastside: calibration row has <${expectedCols} numeric tokens after date (got ${nums.length})`
    );
  }

  const cols = nums.slice(0, expectedCols);
  const colXs = cols.map((c) => c.x);

  if (VERBOSE) {
    console.log("EASTSIDE 7/10 first-N numeric tokens (x,value):");
    cols.forEach((c, i) =>
      console.log(`  col${i + 1}: x=${Math.round(c.x)} v=${c.n}`)
    );
  }

  const centers = {};
  for (let i = 0; i < activeEast.length; i++) {
    const rk = activeEast[i];
    const dailyX = colXs[i * 2 + 0];
    const cumX = colXs[i * 2 + 1];
    if (Math.abs(cumX - dailyX) < 15) {
      throw new Error(
        `eastside: calibration daily/cum columns too close for ${rk} (x=${dailyX},${cumX})`
      );
    }
    centers[rk] = { dailyX, cumX };
  }

  if (VERBOSE) {
    console.log("EASTSIDE centers from calibration:");
    for (const rk of activeEast) {
      console.log(
        `  ${rk}: dailyX=${Math.round(centers[rk].dailyX)} cumX=${Math.round(
          centers[rk].cumX
        )}`
      );
    }
  }

  // Build column centers and index mapping based on *active* rivers only.
  const colCenters = colXs.slice();
  const colIndexByRiver = {};
  for (let i = 0; i < activeEast.length; i++) {
    const rk = activeEast[i];
    colIndexByRiver[rk] = { daily: i * 2, cum: i * 2 + 1 };
  }

  return { centers, colCenters, colIndexByRiver, activeEast };
}

function pickNearestToken(tokens, targetX, maxDx = 120) {
  let best = null;
  let bestDx = Infinity;
  for (const t of tokens) {
    const dx = Math.abs(t.x - targetX);
    if (dx < bestDx) {
      bestDx = dx;
      best = t;
    }
  }
  if (!best || bestDx > maxDx) return null;
  return { n: best.n, x: best.x, dx: bestDx };
}

async function parseEastsidePages(pdf, pages, year, mapping) {
  // mapping: { centers, colCenters, colIndexByRiver, activeEast } OR { centers }
  const centers = mapping.centers ?? mapping;
  const activeEast = mapping.activeEast ?? getActiveEastRivers();

  const colCenters =
    mapping.colCenters ??
    [
      centers.kvichak?.dailyX,
      centers.kvichak?.cumX,
      centers.naknek?.dailyX,
      centers.naknek?.cumX,
      centers.alagnak?.dailyX,
      centers.alagnak?.cumX,
      centers.egegik?.dailyX,
      centers.egegik?.cumX,
      centers.ugashik?.dailyX,
      centers.ugashik?.cumX,
    ].filter((x) => typeof x === "number");

  const colIndexByRiver =
    mapping.colIndexByRiver ??
    (() => {
      const idx = {};
      for (let i = 0; i < activeEast.length; i++) {
        const rk = activeEast[i];
        idx[rk] = { daily: i * 2, cum: i * 2 + 1 };
      }
      return idx;
    })();

  const out = [];

  for (const p of pages) {
    const { items, mode } = await pageItemsSmart(pdf, p, {
      forceOcr: true,
      ocrDpi: 400,
      minDates: 2,
      minNums: 10,
    });
    if (!items.length) continue;

    const lines = groupByLine(items, mode === "ocr" ? 10 : 2);

    for (const ln of lines) {
      const dateIt = ln.items.find((it) => looksLikeDateToken(it.str));
      if (!dateIt) continue;

      const dateISO = isoFromMD(dateIt.str, year);
      if (!dateISO) continue;

      const toks = getMergedNumericTokensAfterDate(ln.items, dateIt.x);
      if (!toks.length) continue;

      if (!KVICHIK_DEBUG_PRINTED && dateISO === "2020-06-22") {
        KVICHIK_DEBUG_PRINTED = true;
        console.log("\n[DEBUG kvichak 2020-06-22] merged numeric tokens after date:");
        toks.forEach((t) => {
          console.log(`  x=${Math.round(t.x)} n=${t.n} raw="${t.raw}"`);
        });
      }

      // Geometry-based assignment: nearest column center wins
      const bestByCol = new Array(colCenters.length).fill(null);
      for (const t of toks) {
        let bestIdx = -1;
        let bestDx = Infinity;
        for (let i = 0; i < colCenters.length; i++) {
          const dx = Math.abs(t.x - colCenters[i]);
          if (dx < bestDx) {
            bestDx = dx;
            bestIdx = i;
          }
        }
        if (bestIdx < 0) continue;
        const prev = bestByCol[bestIdx];
        if (!prev || bestDx < prev.dx) {
          bestByCol[bestIdx] = { n: t.n, x: t.x, dx: bestDx };
        }
      }

      for (const rk of activeEast) {
        let daily = null;
        let cum = null;
        let flags = "";

        const idx = colIndexByRiver[rk];
        const dTok = idx ? bestByCol[idx.daily] : null;
        const cTok = idx ? bestByCol[idx.cum] : null;

        if (dTok) daily = dTok.n;
        if (cTok) cum = cTok.n;

        // 🔹 Egegik fallback by positional columns when geometry misses:
        //    If daily or cum is still missing, use the 4th pair of numeric
        //    tokens after the date (cols 6 & 7: Egegik daily/cum).
        if (rk === "egegik" && (daily == null || cum == null) && toks.length >= 8) {
          const colTokens = toks.slice(6, 8); // [egegik_daily, egegik_cum]
          if (daily == null && colTokens[0]) daily = colTokens[0].n;
          if (cum == null && colTokens[1]) cum = colTokens[1].n;
        }

        // Conservative single-token fill:
        if ((daily == null) !== (cum == null)) {
          const union = (toks || []).filter((t) => {
            const dxD = Math.abs(t.x - colCenters[idx.daily]);
            const dxC = Math.abs(t.x - colCenters[idx.cum]);
            return dxD <= 250 || dxC <= 250;
          });

          const uniq = [];
          for (const t of union) {
            if (!uniq.some((u) => Math.abs(u.x - t.x) < 2)) uniq.push(t);
          }

          if (uniq.length === 1) {
            const t = uniq[0];
            const dxD = Math.abs(t.x - colCenters[idx.daily]);
            const dxC = Math.abs(t.x - colCenters[idx.cum]);
            if (dxD <= 250 && dxC <= 250 && t.n != null && t.n > 0) {
              daily = daily ?? t.n;
              cum = cum ?? t.n;
              flags =
                (flags ? flags + "|" : "") +
                "single_token_filled_daily_equals_cum";
            }
          }
        }

        // Determine if the row is operational
        const hasBoth = daily != null && cum != null;
        let op;

        if (rk === "egegik") {
          // For Egegik, be permissive: keep the numbers even if cum<daily
          const effective = cum != null ? cum : daily;
          op = hasBoth && effective > 0;
        } else {
          op = hasBoth && cum >= daily && cum > 0;
        }

        // Decide what to actually write to CSV
        const keepDaily = rk === "egegik" ? daily : op ? daily : null;
        const keepCum = rk === "egegik" ? cum : op ? cum : null;

        if (!hasBoth) {
          flags = flags
            ? `${flags}|missing_daily_or_cum_hard`
            : "missing_daily_or_cum_hard";
        } else if (rk !== "egegik" && cum < daily) {
          flags = flags
            ? `${flags}|cum_lt_daily_misaligned`
            : "cum_lt_daily_misaligned";
        }

        out.push({
          date: dateISO,
          riverKey: rk,
          method: "tower",
          isOperational: op,
          dailyEscapement: keepDaily,
          cumulativeEscapement: keepCum,
          flags,
          notes: `eastside_page_${p}`,
        });
      }
    }
  }

  return out;
}
function enforceEastsideStartLock(rows) {
  // Eastside-specific start-lock:
  // - If EAST_START_MMDD_BY_YEAR has hints for this YEAR, use them as explicit start dates.
  //   * All dates BEFORE startDate => non-operational, values nulled.
  //   * On/after startDate => require BOTH daily & cumulative.
  //   * For Egegik specifically, we do NOT null-out rows when cum<daily; we just mark them suspect.
  // - If no hints for this YEAR, do NOT apply a prestart cut-off; just enforce
  //   the hard rule "both values present" on whatever the parser found.

  const activeEast = getActiveEastRivers();
  const byRiver = new Map();
  for (const r of rows) {
    if (r.method !== "tower") continue;
    if (!activeEast.includes(r.riverKey)) continue;
    if (!byRiver.has(r.riverKey)) byRiver.set(r.riverKey, []);
    byRiver.get(r.riverKey).push(r);
  }

  const hintsForYear =
    (EAST_START_MMDD_BY_YEAR && EAST_START_MMDD_BY_YEAR[YEAR]) || null;

  for (const [rk, arr] of byRiver.entries()) {
    arr.sort((a, b) => a.date.localeCompare(b.date));

    const mmdd = hintsForYear ? hintsForYear[rk] : null;
    const startDate = mmdd ? `${YEAR}-${mmdd}` : null;

    for (const r of arr) {
      const d = r.dailyEscapement;
      const c = r.cumulativeEscapement;
      const hasBoth = d != null && c != null;

      // If we have a configured start date, wipe everything before it.
      if (startDate && r.date < startDate) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags =
          (r.flags ? r.flags + "|" : "") + "prestart_untrusted_alignment";
        continue;
      }

      // On/after startDate OR when we have no hint: require both values.
      if (!hasBoth) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags =
          (r.flags ? r.flags + "|" : "") + "missing_daily_or_cum_hard";
        continue;
      }

      // Egegik: be maximally permissive after start date — keep values even if cum<daily.
      if (rk === "egegik") {
        if (c < d) {
          r.flags =
            (r.flags ? r.flags + "|" : "") + "egegik_cum_lt_daily_suspect";
        }
        if (c <= 0 || d <= 0) {
          r.flags =
            (r.flags ? r.flags + "|" : "") + "egegik_nonpositive_suspect";
        }
        r.isOperational = true;
        continue;
      }

      // Other eastside rivers: still enforce basic coherence.
      if (c <= 0 || d <= 0 || c < d) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags =
          (r.flags ? r.flags + "|" : "") +
          "missing_daily_or_cum_hard_or_incoherent";
        continue;
      }

      r.isOperational = true;
    }
  }
}

const WEST_RIVERS = ["wood", "igushik", "togiak"];

function inferRiverBoundsFromHeader(lines, headerIdx, riverKeys, scanLines = 80) {
  const anchors = {};
  const end = Math.min(lines.length, headerIdx + scanLines);
  for (let i = headerIdx; i < end; i++) {
    const lineTxt = normalize(lines[i].items.map((it) => it.str).join(" "));
    const headerish = lineTxt.includes("river") || lineTxt.includes("date") || lineTxt.includes("daily");
    if (!headerish && i > headerIdx + 25) continue;
    for (const it of lines[i].items) {
      const tok = normalize(it.str);
      for (const rk of riverKeys) {
        if (tok === rk || tok.startsWith(rk + " ")) {
          anchors[rk] = anchors[rk] == null ? it.x : Math.min(anchors[rk], it.x);
        }
      }
    }
  }
  const missing = riverKeys.filter((rk) => anchors[rk] == null);
  if (missing.length) {
    throw new Error(`inferRiverBounds: missing anchors for ${missing.join(", ")}`);
  }
  const keys = riverKeys.slice().sort((a, b) => anchors[a] - anchors[b]);
  const xs = keys.map((k) => anchors[k]);
  const bounds = [];
  for (let i = 0; i < keys.length; i++) {
    const left = i === 0 ? -1e9 : (xs[i - 1] + xs[i]) / 2;
    const right = i === keys.length - 1 ? 1e9 : (xs[i] + xs[i + 1]) / 2;
    bounds.push({ riverKey: keys[i], left, right, anchorX: xs[i] });
  }
  return bounds;
}

function inferDailyCumCentersFromCalibrationRow(lines, bounds, year) {
  const preferred = ["7/10", "7/11", "7/9", "7/12", "7/8", "7/13"];
  function lineHasTwoNumbersPerRiver(ln) {
    const merged = mergeSplitNumbersRow(ln.items);
    for (const b of bounds) {
      const nums = merged
        .filter((it) => it.x >= b.left && it.x < b.right)
        .map((it) => toNumSafe(it.str))
        .filter((n) => n != null);
      if (nums.length < 2) return false;
    }
    return true;
  }
  function findLineByMMDD_local(mmdd) {
    return lines.find((ln) =>
      ln.items.some((it) => looksLikeDateToken(it.str) && normalizeDateToken(it.str).startsWith(mmdd))
    );
  }
  let calLine = null;
  for (const mmdd of preferred) {
    const ln = findLineByMMDD_local(mmdd);
    if (ln && lineHasTwoNumbersPerRiver(ln)) { calLine = ln; break; }
  }
  if (!calLine) {
    for (const ln of lines) {
      const dateIt = ln.items.find((it) => looksLikeDateToken(it.str));
      if (!dateIt) continue;
      const iso = isoFromMD(dateIt.str, year);
      if (!iso) continue;
      if (lineHasTwoNumbersPerRiver(ln)) { calLine = ln; break; }
    }
  }
  if (!calLine) return null;
  const merged = mergeSplitNumbersRow(calLine.items);
  const centers = {};
  for (const b of bounds) {
    const tokens = merged
      .filter((it) => it.x >= b.left && it.x < b.right)
      .map((it) => ({ x: it.x, n: toNumSafe(it.str) }))
      .filter((o) => o.n != null)
      .sort((a, b) => a.x - b.x);
    if (tokens.length < 2) continue;
    const leftX = tokens[0].x;
    const rightX = tokens[tokens.length - 1].x;
    if (Math.abs(rightX - leftX) < 18) continue;
    centers[b.riverKey] = { dailyX: leftX, cumX: rightX };
  }
  const missing = bounds.map((b) => b.riverKey).filter((rk) => !centers[rk]);
  if (missing.length) return null;
  return centers;
}

function parseTowerPagesWithSharedGeometry(pagesLines, riverKeys, year, labelForVerbose) {
  if (!pagesLines.length) return [];

  // Find the header line for the westside table
  const headerIdx = findFirstLineIndex(pagesLines[0].lines, (ln) => {
    const t = normalize(ln.items.map((it) => it.str).join(" "));
    return (
      t.includes("river") &&
      (t.includes("date") ||
        t.includes("daily") ||
        t.includes("cum") ||
        t.includes("cumulative"))
    );
  });

  const bounds = inferRiverBoundsFromHeader(
    pagesLines[0].lines,
    Math.max(0, headerIdx),
    riverKeys,
    90
  );
  const centers = inferDailyCumCentersFromCalibrationRow(
    pagesLines[0].lines,
    bounds,
    year
  );

  if (!centers) {
    throw new Error(
      `${labelForVerbose}: calibration failed; could not establish daily/cum centers for all rivers.`
    );
  }

  const out = [];

  for (const pg of pagesLines) {
    for (const ln of pg.lines) {
      const dateIt = ln.items.find((it) => looksLikeDateToken(it.str));
      if (!dateIt) continue;

      const dateISO = isoFromMD(dateIt.str, year);
      if (!dateISO) continue;

      const mergedRow = mergeSplitNumbersRow(ln.items);

      for (const b of bounds) {
        // All numeric tokens in this band for this row
        const bandNums = mergedRow
          .filter((it) => it.x >= b.left && it.x < b.right)
          .map((it) => ({ x: it.x, n: toNumSafe(it.str) }))
          .filter((o) => o.n != null)
          .sort((a, b) => a.x - b.x);

        let dailyTok = null;
        let cumTok = null;

        if (b.riverKey === "wood") {
          // 🔹 Wood River: table layout is stable — first numeric in band is daily,
          // second is cumulative. This avoids over-strict geometry assumptions.
          if (bandNums.length >= 1) dailyTok = bandNums[0];
          if (bandNums.length >= 2) cumTok = bandNums[1];
        } else {
          // 🔹 Igushik / Togiak: use calibrated centers as before
          dailyTok = pickNearestToken(bandNums, centers[b.riverKey].dailyX);
          cumTok = pickNearestToken(bandNums, centers[b.riverKey].cumX);
        }

        const hasBoth = !!dailyTok && !!cumTok;
        let op = false;
        let flags = "";

        if (!hasBoth) {
          flags = "missing_daily_or_cum_hard";
        } else if (cumTok.n < dailyTok.n) {
          flags = "cum_lt_daily_misaligned";
        } else {
          op = true;
        }

        out.push({
          date: dateISO,
          riverKey: b.riverKey,
          method: "tower",
          isOperational: op,
          dailyEscapement: op ? dailyTok.n : null,
          cumulativeEscapement: op ? cumTok.n : null,
          flags,
          notes: pg.pageNo ? `page_${pg.pageNo}` : "",
        });
      }
    }
  }

  if (!out.some((r) => r.isOperational)) {
    throw new Error(`${labelForVerbose}: no operational tower rows produced.`);
  }

  return out;
}

function parseSonarPages(pagesLines) {
  const out = [];
  let prev = null;

  function parseMD(token) {
    const s = normalizeDateToken(token);
    const m = s.match(/^(\d{1,2})\/(\d{1,2})/);
    if (!m) return null;
    return { mm: Number(m[1]), dd: Number(m[2]) };
  }

  function fixDroppedTens(prevMD, curMD) {
    if (!prevMD || !curMD) return curMD;
    if (prevMD.mm !== curMD.mm) return curMD;
    if (prevMD.dd >= 10 && curMD.dd < 10) return { mm: curMD.mm, dd: curMD.dd + 10 };
    return curMD;
  }

  function mdToISO(mm, dd) {
    return `${YEAR}-${pad2(mm)}-${pad2(dd)}`;
  }

  for (const pg of pagesLines) {
    for (const ln of pg.lines) {
      const dateIt = ln.items.find((it) => looksLikeDateToken(it.str));
      if (!dateIt) continue;

      let md = parseMD(dateIt.str);
      if (!md) continue;
      md = fixDroppedTens(prev, md);
      prev = md;

      const dateISO = mdToISO(md.mm, md.dd);

      const merged = mergeSplitNumbersRow(ln.items);
      const right = merged
        .filter((it) => it.x > dateIt.x + 2)
        .sort((a, b) => a.x - b.x);

      const nums = right.map((it) => toNumSafe(it.str)).filter((n) => n != null);
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
  }

  return out;
}

/**
 * Non-eastside tower start-lock:
 *  - For non-east rivers, find min coherent cumulative and enforce:
 *    * no tower data before that “lock” day,
 *    * monotone non-decreasing cumulative afterward.
 */
function enforceTowerStartLock(rows) {
  const byRiver = new Map();

  for (const r of rows) {
    if (r.method !== "tower") continue;
    if (EAST_RIVERS.includes(r.riverKey)) continue; // eastside handled separately
    if (!byRiver.has(r.riverKey)) byRiver.set(r.riverKey, []);
    byRiver.get(r.riverKey).push(r);
  }

  for (const [rk, arr] of byRiver.entries()) {
    arr.sort((a, b) => a.date.localeCompare(b.date));

    let minCum = null;
    for (const r of arr) {
      const d = r.dailyEscapement;
      const c = r.cumulativeEscapement;
      if (d == null || c == null) continue;
      if (d <= 0) continue;
      if (c <= 0) continue;
      if (c < d) continue;
      if (minCum == null || c < minCum) minCum = c;
    }

    if (minCum == null) continue;

    let lockIdx = -1;
    for (let i = 0; i < arr.length; i++) {
      const d = arr[i].dailyEscapement;
      const c = arr[i].cumulativeEscapement;
      if (d != null && c != null && d > 0 && c > 0 && d === c && c === minCum) {
        lockIdx = i;
        break;
      }
    }

    if (lockIdx < 0) {
      for (const r of arr) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags = (r.flags ? r.flags + "|" : "") + "no_trustworthy_lock_day";
      }
      continue;
    }

    // Pre-lock rows: always non-operational
    for (let i = 0; i < lockIdx; i++) {
      const r = arr[i];
      r.isOperational = false;
      r.dailyEscapement = null;
      r.cumulativeEscapement = null;
      r.flags = (r.flags ? r.flags + "|" : "") + "prestart_untrusted_alignment";
    }

    // Post-lock: require both values, cum>=daily, and non-decreasing cum
    let lastCum = minCum;
    for (let i = lockIdx; i < arr.length; i++) {
      const r = arr[i];
      const d = r.dailyEscapement;
      const c = r.cumulativeEscapement;

      if (d != null && d <= 0) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags = (r.flags ? r.flags + "|" : "") + "daily_zero_placeholder";
        continue;
      }

      if (d == null || c == null) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags = (r.flags ? r.flags + "|" : "") + "missing_daily_or_cum";
        continue;
      }

      if (c < d) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags = (r.flags ? r.flags + "|" : "") + "cum_lt_daily_misaligned";
        continue;
      }

      if (c < lastCum) {
        r.isOperational = false;
        r.dailyEscapement = null;
        r.cumulativeEscapement = null;
        r.flags = (r.flags ? r.flags + "|" : "") + "cum_decreased_misaligned";
        continue;
      }

      r.isOperational = true;
      lastCum = c;
    }
  }
}

/* -------------------------
 * MAIN
 * ------------------------- */

(async () => {
  const pdf = await loadPdf(PDF_PATH);

  const ACTIVE_EAST_RIVERS = getActiveEastRivers();

  const HDR_EAST =
    "daily sockeye salmon escapement tower counts by river system, eastside bristol bay";
  const HDR_WEST =
    "daily sockeye salmon escapement tower counts by river system, bristol bay westside";

  let eastPage = null;
  let westPage = null;
  let sonarPage = null;

  // ------------ HEADER DISCOVERY PASS ------------
  for (let p = 1; p <= pdf.numPages; p++) {
    const { items } = await pageItemsSmart(pdf, p, {
      forceOcr: true,
      ocrDpi: 350,
      minDates: 2,
      minNums: 10,
    });
    if (!items.length) continue;

    const big = normalize(items.map((i) => i.str).join(" "));
    if (looksLikeOpeningSchedule(big)) continue;

    const dateTokCount = items.filter((it) => looksLikeDateToken(it.str)).length;
    const numTokCount = items.filter((it) => isNumericFragment(it.str)).length;

    // EASTSIDE header
    if (!eastPage) {
const eastSidePhrase =
  big.includes("east side bristol bay") ||
  big.includes("eastside bristol bay") ||
  big.includes("east side bristol") ||
  big.includes("bristol bay east side") ||
  big.includes("bristol bay eastside");

      const hasHeaderCore =
        big.includes("daily sockeye salmon escapement") &&
        big.includes("tower counts") &&
        big.includes("river system");
        
      const hasTable7 = big.includes("table 7");

      const looksLikeSonarHeader =
        big.includes("nushagak river sonar project") &&
        (big.includes("daily and cumulative") ||
          big.includes("passage estimate") ||
          big.includes("passage estimates")) &&
        big.includes("sockeye");

      const eastHeaderLike =
        eastSidePhrase &&
        (hasHeaderCore || hasTable7) &&
        !looksLikeSonarHeader &&
        dateTokCount >= 2 &&
        numTokCount >= 15;

      if (eastHeaderLike) {
        eastPage = p;
        if (VERBOSE) {
          console.log(
            `page ${p}: eastside header page detected (year=${YEAR}, p=${p}, dates=${dateTokCount}, nums=${numTokCount})`
          );
        }
      }
    }

        // WESTSIDE header (works for 2017–2024+)
    if (!westPage) {
      // Variants across years / OCR:
      //   - "bristol bay westside"
      //   - "bristol bay west side"
      //   - "westside bristol bay"
      //   - "west side bristol bay"
      const westSidePhrase =
        big.includes("bristol bay westside") ||
        big.includes("bristol bay west side") ||
        big.includes("bristol bay west") ||
        big.includes("westside bristol bay") ||
        big.includes("west side bristol bay") ||
        big.includes("westside bristol");

      const hasHeaderCoreWest =
        big.includes("daily sockeye salmon escapement") &&
        big.includes("tower counts") &&
        big.includes("river system");

      // In older reports westside was often Table 8; in newer (e.g. 2024) it’s Table 17.
      const hasTableTag =
        big.includes("table 8") ||
        big.includes("table 17");

      const westHeaderLike =
        westSidePhrase &&
        (hasHeaderCoreWest || hasTableTag) &&
        dateTokCount >= 2 &&
        numTokCount >= 15;

      if (westHeaderLike) {
        westPage = p;
        if (VERBOSE) {
          console.log(
            `page ${p}: westside header page detected (year=${YEAR}, p=${p}, dates=${dateTokCount}, nums=${numTokCount})`
          );
        }
      }
    }

       // SONAR header (Nushagak sonar table only)
    if (!sonarPage) {
      // Canonical header across years looks like:
      // "Table 7. –Daily and cumulative passage estimates by salmon species,
      //  Nushagak River sonar project, Bristol Bay, 2024."
      // OCR may mangle "project" or split the line, so we allow a few variants.
      const sonarHeaderLike =
        (
          // Strong canonical match
          (big.includes("nushagak river sonar project") &&
           (big.includes("daily and cumulative") ||
            big.includes("passage estimate") ||
            big.includes("passage estimates")))
          ||
          // 2024-style fallback: table 7 + nushagak + sonar + passage
          (big.includes("table 7") &&
           big.includes("nushagak") &&
           big.includes("sonar") &&
           (big.includes("daily and cumulative") ||
            big.includes("passage estimate") ||
            big.includes("passage estimates")))
        ) &&
        // never a tower table
        !big.includes("tower counts") &&
        !big.includes("eastside bristol bay") &&
        !big.includes("east side bristol bay") &&
        !big.includes("bristol bay westside") &&
        !big.includes("bristol bay west side");

      if (sonarHeaderLike) {
        const sonarDateCount = items.filter((it) => looksLikeDateToken(it.str)).length;
        const sonarNumCount  = items.filter((it) => isNumericFragment(it.str)).length;

        // Real sonar table pages have lots of dates and lots of numbers
        if (sonarDateCount >= 10 && sonarNumCount >= 40) {
          const score = sonarDateCount * 1000 + sonarNumCount;
          if (!sonarPage || score > sonarPage.score) {
            sonarPage = { p, score };
          }
        }
      }
    }
    if (eastPage && westPage && sonarPage) break;
  }

  // End of header discovery loop
  // Post-loop checks:
  if (!eastPage) throw new Error("Could not locate eastside tower header page.");
  if (!westPage) throw new Error("Could not locate westside tower header page.");
  if (!sonarPage) throw new Error("Could not locate sonar header page.");

  const sonarHeaderPage = sonarPage.p;
  if (VERBOSE) console.log(`sonar header page selected: ${sonarHeaderPage}`);

  // Eastside continuation pages (up to +3)
  const eastPages = [eastPage];
  for (let k = 1; k <= 3; k++) {
    const p2 = eastPage + k;
    if (p2 > pdf.numPages) break;

    const { items } = await pageItemsSmart(pdf, p2, {
      forceOcr: true,
      ocrDpi: 350,
      minDates: 2,
      minNums: 10,
    });
    if (!items.length) break;

    const big = normalize(items.map((i) => i.str).join(" "));
    if (looksLikeOpeningSchedule(big)) break;

    const dateCount = (big.match(/\b\d{1,2}[\/|]\d{1,2}\b/g) || []).length;
    const hits = ACTIVE_EAST_RIVERS.filter((rk) => big.includes(rk)).length;

    if (dateCount >= 10 && hits >= 2 && big.includes("daily") &&
        (big.includes("cum") || big.includes("cumulative"))) {
      eastPages.push(p2);
    } else {
      break;
    }
  }

  // Westside (2 pages)
  const westPages = [westPage, westPage + 1].filter(
    (p) => p >= 1 && p <= pdf.numPages
  );

    const sonarPages = [sonarHeaderPage];

  for (let k = 1; k <= 2; k++) {
    const p2 = sonarHeaderPage + k;
    if (p2 < 1 || p2 > pdf.numPages) break;

    const { items } = await pageItemsSmart(pdf, p2, {
      forceOcr: true,
      ocrDpi: 350,
      minDates: 2,
      minNums: 10,
    });
    if (!items.length) break;

    const big = normalize(items.map((i) => i.str).join(" "));

    // Continuation pages often say "Table 7.-Page 2 of 2" and may omit
    // the long description. Detect them by table 7 + species headers,
    // and exclude any tower-style pages.
    const looksLikeSonarContinuation =
      (
        big.includes("nushagak river sonar") ||
        (big.includes("table 7") && big.includes("page 2 of 2"))
      ) &&
      // These are species/column labels on the sonar table, not tower headers
      (big.includes("sockeye") || big.includes("chinook") || big.includes("chum")) &&
      !big.includes("tower counts") &&
      !big.includes("eastside bristol bay") &&
      !big.includes("east side bristol bay") &&
      !big.includes("daily sockeye salmon escapement");

    if (!looksLikeSonarContinuation) break;

    sonarPages.push(p2);
  }

  async function loadPageLines(pageNo, dpi) {
    const { items, mode } = await pageItemsSmart(pdf, pageNo, {
      forceOcr: true,
      ocrDpi: dpi,
      minDates: 2,
      minNums: 10,
    });
    const lines = groupByLine(items, 10.0);
    return { pageNo, mode, lines, items };
  }

  const eastPL = [];
  for (const p of eastPages) eastPL.push(await loadPageLines(p, 400));

  const westPL = [];
  for (const p of westPages) westPL.push(await loadPageLines(p, 400));

  const sonarPL = [];
  for (const p of sonarPages) sonarPL.push(await loadPageLines(p, 400));

  const allRows = [];

  // EASTSIDE
  {
    const headerLines = eastPL[0].lines;
    const mapping = buildEastsideCentersFrom0710(headerLines);
    const rows = await parseEastsidePages(pdf, eastPages, YEAR, mapping);
    enforceEastsideStartLock(rows);
    if (VERBOSE)
      console.log(
        `eastside tower parsed rows=${rows.length} pages=${eastPages.join(",")}`
      );
    allRows.push(...rows);
  }

  // WESTSIDE
  {
    const rows = parseTowerPagesWithSharedGeometry(
      westPL.map((x) => ({ pageNo: x.pageNo, lines: x.lines })),
      WEST_RIVERS,
      YEAR,
      "westside"
    );
    if (VERBOSE)
      console.log(
        `westside tower parsed rows=${rows.length} pages=${westPages.join(",")}`
      );
    allRows.push(...rows);
  }

  // SONAR
  {
    const rows = parseSonarPages(
      sonarPL.map((x) => ({ pageNo: x.pageNo, lines: x.lines }))
    );
    if (VERBOSE)
      console.log(
        `sonar parsed rows=${rows.length} pages=${sonarPages.join(",")}`
      );
    allRows.push(...rows);
  }

  // Dedup + global tower start lock (non-eastside)
  const byKey = new Map();
  for (const r of allRows) {
    byKey.set(`${r.date}__${r.riverKey}__${r.method}`, r);
  }

  const final = Array.from(byKey.values()).sort(
    (a, b) =>
      a.date.localeCompare(b.date) ||
      a.riverKey.localeCompare(b.riverKey) ||
      a.method.localeCompare(b.method)
  );

  enforceTowerStartLock(final);

  const header =
    "date,riverKey,method,isOperational,dailyEscapement,cumulativeEscapement,flags,notes\n";
  const csv =
    header +
    final
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

  fs.writeFileSync(OUT, csv, "utf8");
  console.log(`✅ wrote ${OUT} (${final.length} rows)`);
})().catch((err) => {
  console.error("FAILED:", err);
  process.exit(1);
});
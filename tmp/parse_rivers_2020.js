/**
 * tmp/parse_rivers_2020.js
 *
 * Input:
 *   src/data/2020/raw/eastside_table7.txt   (Kvichak, Naknek, Alagnak, Egegik, Ugashik)
 *   src/data/2020/raw/westside_table17.txt  (Wood, Igushik, Togiak)
 *
 * Output:
 *   src/data/2020/rivers_2020.csv
 *
 * CSV schema:
 * date,riverKey,method,isOperational,dailyEscapement,cumulativeEscapement,flags,notes
 *
 * Rules:
 * - “Blank / ND / –” => isOperational=false, dailyEscapement=null, cumulativeEscapement=null
 * - We do NOT coerce ND to 0 (avoids nd_not_null validation).
 * - We ignore “Table…”, “Page…”, “continued…”, etc.
 */

const fs = require("fs");

const YEAR = 2020;

const IN_EAST = `src/data/${YEAR}/raw/eastside_table7.txt`;
const IN_WEST = `src/data/${YEAR}/raw/westside_table17.txt`;
const OUT = `src/data/${YEAR}/rivers_${YEAR}.csv`;

function pad2(n) {
  return String(n).padStart(2, "0");
}
function isoFromMD(md) {
  const [m, d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}

function cleanToken(t) {
  return String(t ?? "")
    .replace(/\u00A0/g, " ")     // NBSP -> space
    .replace(/[,\u2009]/g, "")   // commas + thin spaces
    .replace(/[–—]/g, "-")       // normalize dashes
    .trim();
}

function isMissingToken(t) {
  const s = cleanToken(t).toUpperCase();
  return s === "" || s === "-" || s === "ND";
}

function toIntOrNull(t) {
  if (isMissingToken(t)) return null;
  const s = cleanToken(t);
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

function getRelevantLines(raw) {
  return raw
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
    .filter((l) => /\b\d{1,2}\/\d{1,2}\b/.test(l))
    .filter((l) => !/^Table\b/i.test(l))
    .filter((l) => !/continued/i.test(l))
    .filter((l) => !/^Page\b/i.test(l));
}

// Parse a line into [dateISO, tokens[]] where tokens are "daily/cum" pairs flattened
function extractDateAndTokens(line) {
  const mdMatch = line.match(/\b(\d{1,2}\/\d{1,2})\b/);
  if (!mdMatch) return null;
  const md = mdMatch[1];
  const dateISO = isoFromMD(md);

  // Remove everything before the date token to reduce junk, then split
  const idx = line.indexOf(md);
  const tail = line.slice(idx + md.length).trim();

  // tokens = numbers / ND / - (drop pure letters)
  const toks = tail
    .split(/\s+/)
    .map(cleanToken)
    .filter((t) => t.length > 0)
    .filter((t) => !/^[a-z]+$/i.test(t));

  return { dateISO, toks };
}

/**
 * EASTSIDE (5 rivers): kvichak, naknek, alagnak, egegik, ugashik
 * We expect daily/cum pairs in order, but early rows may omit leading rivers.
 *
 * Strategy:
 * - If toks length is 10 => perfect (5*2).
 * - If toks length is shorter, we assume missing *leading* rivers (they weren’t operational yet)
 *   and right-align the remaining pairs to the last rivers in the order.
 */
function parseEastside(text) {
  const rivers = ["kvichak", "naknek", "alagnak", "egegik", "ugashik"];
  const rows = [];

  for (const line of getRelevantLines(text)) {
    const parsed = extractDateAndTokens(line);
    if (!parsed) continue;
    const { dateISO, toks } = parsed;

    // Convert tokens into pairs
    const pairCount = Math.floor(toks.length / 2);
    const pairs = [];
    for (let i = 0; i < pairCount; i++) {
      pairs.push([toks[i * 2], toks[i * 2 + 1]]);
    }

    // Right-align pairs onto rivers (handles early season where only egegik/ugashik show up)
    const startRiverIdx = Math.max(0, rivers.length - pairs.length);

    for (let rIdx = 0; rIdx < rivers.length; rIdx++) {
      const rk = rivers[rIdx];
      const pIdx = rIdx - startRiverIdx;

      if (pIdx < 0 || pIdx >= pairs.length) {
        rows.push([dateISO, rk, "tower", "false", "", "", "", ""]);
        continue;
      }

      const [dTok, cTok] = pairs[pIdx];
      const daily = toIntOrNull(dTok);
      const cum = toIntOrNull(cTok);

      if (daily == null && cum == null) {
        rows.push([dateISO, rk, "tower", "false", "", "", "", ""]);
      } else {
        rows.push([dateISO, rk, "tower", "true", daily ?? "", cum ?? "", "", ""]);
      }
    }
  }

  return rows;
}

/**
 * WESTSIDE (3 rivers): wood, igushik, togiak
 * Expected pairs (wood d/c, igushik d/c, togiak d/c), but blanks may exist.
 *
 * Strategy:
 * - If 6 tokens => perfect.
 * - If shorter, right-align pairs to the last rivers (often early: only wood, then wood+igushik, then all 3).
 */
function parseWestside(text) {
  const rivers = ["wood", "igushik", "togiak"];
  const rows = [];

  for (const line of getRelevantLines(text)) {
    const parsed = extractDateAndTokens(line);
    if (!parsed) continue;
    const { dateISO, toks } = parsed;

    const pairCount = Math.floor(toks.length / 2);
    const pairs = [];
    for (let i = 0; i < pairCount; i++) {
      pairs.push([toks[i * 2], toks[i * 2 + 1]]);
    }

    const startRiverIdx = Math.max(0, rivers.length - pairs.length);

    for (let rIdx = 0; rIdx < rivers.length; rIdx++) {
      const rk = rivers[rIdx];
      const pIdx = rIdx - startRiverIdx;

      if (pIdx < 0 || pIdx >= pairs.length) {
        rows.push([dateISO, rk, "tower", "false", "", "", "", ""]);
        continue;
      }

      const [dTok, cTok] = pairs[pIdx];
      const daily = toIntOrNull(dTok);
      const cum = toIntOrNull(cTok);

      if (daily == null && cum == null) {
        rows.push([dateISO, rk, "tower", "false", "", "", "", ""]);
      } else {
        rows.push([dateISO, rk, "tower", "true", daily ?? "", cum ?? "", "", ""]);
      }
    }
  }

  return rows;
}

function main() {
  if (!fs.existsSync(IN_EAST)) throw new Error(`Missing ${IN_EAST}`);
  if (!fs.existsSync(IN_WEST)) throw new Error(`Missing ${IN_WEST}`);

  const eastText = fs.readFileSync(IN_EAST, "utf8");
  const westText = fs.readFileSync(IN_WEST, "utf8");

  const out = [];
  out.push("date,riverKey,method,isOperational,dailyEscapement,cumulativeEscapement,flags,notes");

  const eastRows = parseEastside(eastText);
  const westRows = parseWestside(westText);

  for (const r of [...eastRows, ...westRows]) out.push(r.join(","));

  fs.writeFileSync(OUT, out.join("\n") + "\n", "utf8");
  console.log(`✅ wrote ${OUT} (${out.length - 1} rows)`);
}

main();

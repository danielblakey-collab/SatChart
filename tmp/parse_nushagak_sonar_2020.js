/**
 * tmp/parse_nushagak_sonar_2020.js
 *
 * Input:  src/data/2020/raw/nushagak_sonar_table.txt
 * Output: appends sonar rows into src/data/2020/rivers_2020.csv
 *
 * Expects lines like:
 * 6/6  330  330   ...
 * We only read Sockeye Daily + Sockeye Cumulative (first two numeric columns after date).
 *
 * Rules:
 * - ND / – / blanks => isOperational=false and daily/cum blank
 * - commas inside numbers allowed
 */

const fs = require("fs");

const YEAR = 2020;
const INP = `src/data/${YEAR}/raw/nushagak_sonar_table.txt`;
const OUT = `src/data/${YEAR}/rivers_${YEAR}.csv`;

function pad2(n){ return String(n).padStart(2,"0"); }
function isoFromMD(md){
  const [m,d] = md.split("/").map(Number);
  return `${YEAR}-${pad2(m)}-${pad2(d)}`;
}

function clean(s){
  return String(s ?? "").replace(/\u00A0/g," ").replace(/[–—]/g,"-").trim();
}

function isMissing(tok){
  const t = clean(tok).toUpperCase();
  return t === "" || t === "-" || t === "ND";
}

function toNum(tok){
  if (isMissing(tok)) return null;
  const t = clean(tok).replace(/,/g,"");
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

function main(){
  if (!fs.existsSync(INP)) throw new Error(`Missing ${INP}`);
  if (!fs.existsSync(OUT)) throw new Error(`Missing ${OUT} (run parse_rivers_2020.js first)`);

  const lines = fs.readFileSync(INP,"utf8").split(/\r?\n/).map(l=>l.trim()).filter(Boolean);

  const outLines = [];

  for (const line of lines){
    // Find a date token like 6/6 (optionally with footnote like 6/6a)
    const m = line.match(/\b(\d{1,2}\/\d{1,2})[a-z]?\b/i);
    if (!m) continue;

    const md = m[1];
    const dateISO = isoFromMD(md);

    // Remove everything before the date token then split into tokens
    const idx = line.indexOf(m[0]);
    const tail = line.slice(idx + m[0].length).trim();
    const toks = tail.split(/\s+/).map(clean).filter(Boolean);

    // Need at least Sockeye daily + cumulative
    const daily = toNum(toks[0]);
    const cum   = toNum(toks[1]);

    if (daily == null && cum == null){
      outLines.push(`${dateISO},nushagak,sonar,false,,,,`);
    } else {
      outLines.push(`${dateISO},nushagak,sonar,true,${daily ?? ""},${cum ?? ""},,`);
    }
  }

  if (!outLines.length){
    console.log("⚠️ No sonar lines parsed. Check the raw file formatting.");
    process.exit(0);
  }

  fs.appendFileSync(OUT, outLines.join("\n") + "\n", "utf8");
  console.log(`✅ appended ${outLines.length} sonar rows into ${OUT}`);
}

main();

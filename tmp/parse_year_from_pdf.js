#!/usr/bin/env node
/**
 * parse_year_from_pdf.js
 *
 * Orchestrator:
 *  - Reads a PDF or text dump
 *  - Calls three parser modules:
 *      - tmp/parse_ops_from_pdf.js
 *      - tmp/parse_registration_from_pdf.js
 *      - tmp/parse_rivers_from_pdf.js
 *  - Writes:
 *      - src/data/<year>/ops_<year>.csv
 *      - src/data/<year>/registration_<year>.csv
 *      - src/data/<year>/rivers_<year>.csv
 *
 * Usage:
 *   node tmp/parse_year_from_pdf.js --year=2020 --pdf="src/data/2020/raw/FMR_2020.pdf"
 *   node tmp/parse_year_from_pdf.js --year=2020 --text="src/data/2020/raw/pdf_extracted.txt"
 *
 * Options:
 *   --year=YYYY                 required
 *   --pdf=PATH                  path to PDF
 *   --text=PATH                 path to a plain-text file (skip PDF extraction)
 *   --outDir=src/data/YYYY      default src/data/<year>
 *   --writeExtractedText=1      write extracted text to <outDir>/raw/pdf_extracted.txt
 *   --verbose=1                 print extra logs
 *
 * Notes:
 * - You’ll need `pdf-parse` installed if using --pdf:
 *     npm i pdf-parse
 */

const fs = require("fs");
const path = require("path");

function arg(name, def = null) {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  if (!hit) return def;
  return hit.split("=").slice(1).join("=");
}
function hasFlag(name) {
  return process.argv.includes(`--${name}`) || arg(name, null) === "1" || arg(name, null) === "true";
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function writeCsv(outPath, headerCols, rows) {
  const esc = (v) => {
    if (v === null || v === undefined) return "";
    const s = String(v);
    // quote if contains comma, quote, newline
    if (/[,"\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  };

  const lines = [];
  lines.push(headerCols.join(","));
  for (const r of rows) {
    const line = headerCols.map((k) => esc(r[k])).join(",");
    lines.push(line);
  }
  fs.writeFileSync(outPath, lines.join("\n") + "\n", "utf8");
}

async function extractTextFromPdf(pdfPath) {
  // Lazy-load so users can run with --text without installing pdf-parse
  let pdfParse;
  try {
    pdfParse = require("pdf-parse");
  } catch (e) {
    throw new Error(
      `Missing dependency 'pdf-parse'. Install it in satchart-etl:\n\n  npm i pdf-parse\n\nOriginal error: ${e.message}`
    );
  }

  const dataBuffer = fs.readFileSync(pdfPath);
  const result = await pdfParse(dataBuffer);
  return result.text || "";
}

function requireParser(relPath) {
  const abs = path.resolve(process.cwd(), relPath);
  if (!fs.existsSync(abs)) {
    throw new Error(`Missing parser module: ${relPath}\nExpected at: ${abs}`);
  }
  const mod = require(abs);
  if (!mod || typeof mod.parseFromText !== "function") {
    throw new Error(
      `Parser module ${relPath} must export:\n\n  module.exports.parseFromText = ({ year, text }) => ({ header, rows })\n`
    );
  }
  return mod;
}

async function main() {
  const yearStr = arg("year");
  if (!yearStr) throw new Error("Usage: node tmp/parse_year_from_pdf.js --year=2020 --pdf=PATH");
  const year = Number(yearStr);
  if (!year || year < 2000 || year > 2100) throw new Error(`Bad --year: ${yearStr}`);

  const pdfPath = arg("pdf");
  const textPath = arg("text");
  const verbose = hasFlag("verbose");
  const writeExtractedText = hasFlag("writeExtractedText");

  if (!pdfPath && !textPath) {
    throw new Error("Provide one: --pdf=PATH or --text=PATH");
  }

  const outDir = arg("outDir", path.resolve(process.cwd(), `src/data/${year}`));
  const rawDir = path.join(outDir, "raw");
  ensureDir(outDir);
  ensureDir(rawDir);

  let text = "";
  if (textPath) {
    const abs = path.resolve(process.cwd(), textPath);
    if (!fs.existsSync(abs)) throw new Error(`Missing --text file: ${abs}`);
    text = fs.readFileSync(abs, "utf8");
    if (verbose) console.log(`Loaded text: ${abs} (${text.length} chars)`);
  } else {
    const abs = path.resolve(process.cwd(), pdfPath);
    if (!fs.existsSync(abs)) throw new Error(`Missing --pdf file: ${abs}`);
    if (verbose) console.log(`Extracting PDF text: ${abs}`);
    text = await extractTextFromPdf(abs);
    if (verbose) console.log(`Extracted ${text.length} chars from PDF`);
    if (writeExtractedText) {
      const outTxt = path.join(rawDir, "pdf_extracted.txt");
      fs.writeFileSync(outTxt, text, "utf8");
      console.log(`✅ wrote extracted text: ${outTxt}`);
    }
  }

  // Load parser modules
  const opsParser = requireParser("tmp/parse_ops_from_pdf.js");
  const regParser = requireParser("tmp/parse_registration_from_pdf.js");
  const rivParser = requireParser("tmp/parse_rivers_from_pdf.js");

  // Run parsers
  const opsRes = await opsParser.parseFromText({ year, text });
  const regRes = await regParser.parseFromText({ year, text });
  const rivRes = await rivParser.parseFromText({ year, text });

  // Expect { header: string[], rows: object[] }
  if (!opsRes?.header || !opsRes?.rows) throw new Error("ops parser returned invalid shape");
  if (!regRes?.header || !regRes?.rows) throw new Error("registration parser returned invalid shape");
  if (!rivRes?.header || !rivRes?.rows) throw new Error("rivers parser returned invalid shape");

  const opsOut = path.join(outDir, `ops_${year}.csv`);
  const regOut = path.join(outDir, `registration_${year}.csv`);
  const rivOut = path.join(outDir, `rivers_${year}.csv`);

  writeCsv(opsOut, opsRes.header, opsRes.rows);
  writeCsv(regOut, regRes.header, regRes.rows);
  writeCsv(rivOut, rivRes.header, rivRes.rows);

  console.log(`✅ wrote ${opsOut} (${opsRes.rows.length} rows)`);
  console.log(`✅ wrote ${regOut} (${regRes.rows.length} rows)`);
  console.log(`✅ wrote ${rivOut} (${rivRes.rows.length} rows)`);

  if (verbose) {
    const preview = (rows) => rows.slice(0, 3).map((r) => JSON.stringify(r)).join("\n");
    console.log("\n--- ops preview ---\n" + preview(opsRes.rows));
    console.log("\n--- registration preview ---\n" + preview(regRes.rows));
    console.log("\n--- rivers preview ---\n" + preview(rivRes.rows));
  }
}

main().catch((e) => {
  console.error("FAILED:", e.message || e);
  process.exit(1);
});

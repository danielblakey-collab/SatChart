/* tmp/pdf_ocr_utils.js
 *
 * Render PDF pages -> PNG and OCR them via tesseract TSV.
 * Returns OCR "words" with x/y/width/height + text.
 *
 * Requirements:
 *   npm i canvas execa pdfjs-dist
 *   brew install tesseract
 */

const fs = require("fs");
const path = require("path");
const { execa } = require("execa");

// ✅ Use legacy build for Node (works with your environment)
const pdfjsLib = require("pdfjs-dist/legacy/build/pdf.js");

// DOMMatrix shim (pdfjs needs it)
if (typeof global.DOMMatrix === "undefined") {
  global.DOMMatrix = class DOMMatrix {
    constructor() {}
  };
}

function arg(name, def = null) {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`));
  return a ? a.split("=").slice(1).join("=") : def;
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function pad2(n) {
  return String(n).padStart(2, "0");
}

async function loadPdf(pdfPath) {
  if (!fs.existsSync(pdfPath)) throw new Error(`PDF not found: ${pdfPath}`);
  const data = new Uint8Array(fs.readFileSync(pdfPath));
  return await pdfjsLib.getDocument({ data }).promise;
}

async function renderPageToPng(pdf, pageNum, outPngPath, scale = 3.0) {
  const { createCanvas } = require("canvas");
  const page = await pdf.getPage(pageNum);

  const viewport = page.getViewport({ scale });
  const canvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
  const ctx = canvas.getContext("2d");

  await page.render({ canvasContext: ctx, viewport }).promise;

  ensureDir(path.dirname(outPngPath));
  fs.writeFileSync(outPngPath, canvas.toBuffer("image/png"));
  return { width: canvas.width, height: canvas.height, scale };
}

async function ocrTsv(pngPath) {
  // tesseract image output tsv
  // we suppress console noise
  const { stdout } = await execa("tesseract", [pngPath, "stdout", "--psm", "6", "tsv"], {
    reject: false,
    timeout: 120000,
  });
  return stdout;
}

function parseTsv(tsvText) {
  const lines = tsvText.split(/\r?\n/).filter(Boolean);
  if (!lines.length) return [];
  const header = lines[0].split("\t");
  const idx = {};
  header.forEach((h, i) => (idx[h] = i));

  const out = [];
  for (const line of lines.slice(1)) {
    const cols = line.split("\t");
    const text = cols[idx.text] ?? "";
    if (!text || !text.trim()) continue;

    const conf = Number(cols[idx.conf] ?? "-1");
    if (Number.isFinite(conf) && conf >= 0 && conf < 35) continue; // drop low-confidence junk

    out.push({
      text: text.trim(),
      left: Number(cols[idx.left]),
      top: Number(cols[idx.top]),
      width: Number(cols[idx.width]),
      height: Number(cols[idx.height]),
      conf,
      // convenience
      x: Number(cols[idx.left]),
      y: Number(cols[idx.top]),
      x2: Number(cols[idx.left]) + Number(cols[idx.width]),
      y2: Number(cols[idx.top]) + Number(cols[idx.height]),
      line_num: Number(cols[idx.line_num]),
      block_num: Number(cols[idx.block_num]),
      par_num: Number(cols[idx.par_num]),
    });
  }
  return out;
}

function groupByLine(words, yTol = 10) {
  // group OCR words by approximate y midline
  const items = words
    .map((w) => ({ ...w, yMid: w.top + w.height / 2, xMid: w.left + w.width / 2 }))
    .sort((a, b) => a.yMid - b.yMid || a.xMid - b.xMid);

  const lines = [];
  for (const w of items) {
    const last = lines[lines.length - 1];
    if (!last || Math.abs(last.yMid - w.yMid) > yTol) {
      lines.push({ yMid: w.yMid, words: [w] });
    } else {
      last.words.push(w);
    }
  }
  for (const ln of lines) ln.words.sort((a, b) => a.xMid - b.xMid);
  return lines;
}

function norm(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[–—]/g, "-")
    .replace(/\s+/g, " ")
    .trim();
}

function looksLikeDate(s) {
  return /^\d{1,2}\/\d{1,2}[a-z]?$/.test(String(s).trim().toLowerCase());
}

function toNumberToken(s) {
  const t = String(s || "").trim();
  if (!t) return null;
  if (t === "-" || t === "–" || t.toUpperCase() === "ND") return null;
  const n = Number(t.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

module.exports = {
  arg,
  loadPdf,
  renderPageToPng,
  ocrTsv,
  parseTsv,
  groupByLine,
  norm,
  looksLikeDate,
  toNumberToken,
  pad2,
};

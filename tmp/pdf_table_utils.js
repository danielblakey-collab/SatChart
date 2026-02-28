/**
 * pdf_table_utils.js
 *
 * Shared helpers:
 * - loadPdf(pdfPath)
 * - pageTextItems(pdf, pageNo) -> [{str,x,y}]
 * - pageOcrItems(pdf, pageNo, opts) -> [{str,x,y,w,h,conf,_ocr:true}]
 * - pageItemsSmart(pdf, pageNo, opts) OR pageItemsSmart(pdf, pdfPath, pageNo, opts)
 * - groupByLine(items, yTol)
 * - normalize(str)
 */

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

// ---- polyfills for pdfjs in Node (text extraction only) ----
function ensurePolyfills() {
  if (typeof global.DOMMatrix === "undefined") {
    global.DOMMatrix = class DOMMatrix {
      constructor(init) {
        this.a = 1; this.b = 0; this.c = 0; this.d = 1; this.e = 0; this.f = 0;
        if (Array.isArray(init) && init.length >= 6) {
          [this.a, this.b, this.c, this.d, this.e, this.f] = init;
        }
      }
    };
  }
}

async function importPdfJs() {
  // Always use legacy mjs in Node
  try {
    return await import("pdfjs-dist/legacy/build/pdf.mjs");
  } catch (e) {
    throw new Error(`Failed to import pdfjs-dist legacy/build/pdf.mjs: ${e?.message || e}`);
  }
}

async function loadPdf(pdfPath) {
  ensurePolyfills();

  const abs = path.isAbsolute(pdfPath) ? pdfPath : path.resolve(process.cwd(), pdfPath);
  if (!fs.existsSync(abs)) throw new Error(`PDF not found: ${abs}`);

  const data = new Uint8Array(fs.readFileSync(abs));
  const pdfjs = await importPdfJs();

  try { pdfjs.GlobalWorkerOptions.workerSrc = null; } catch (_) {}

  const loadingTask = pdfjs.getDocument({ data, disableFontFace: true });
  const pdf = await loadingTask.promise;

  pdf.__pdfPathAbs = abs;
  return pdf;
}

function normalize(s) {
  return String(s || "")
    .replace(/\s+/g, " ")
    .replace(/[–—]/g, "-")
    .toLowerCase()
    .trim();
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

function safeGetPage(pdf, pageNoRaw) {
  const pageNo = Number(pageNoRaw);
  if (!Number.isFinite(pageNo)) {
    throw new Error(`Invalid page request: pageNo is not a number (got ${pageNoRaw})`);
  }
  if (pageNo < 1 || pageNo > pdf.numPages) {
    throw new Error(`Invalid page request: ${pageNo} outside 1..${pdf.numPages}`);
  }
  return pdf.getPage(pageNo);
}

async function pageTextItems(pdf, pageNo) {
  const page = await safeGetPage(pdf, pageNo);
  const tc = await page.getTextContent();
  return tc.items
    .filter((it) => it.str && it.str.trim())
    .map((it) => ({ str: it.str.trim(), x: it.transform[4], y: it.transform[5] }));
}

// ---------- OCR via pdftoppm + tesseract (no canvas) ----------

function hasCmd(cmd) {
  const r = spawnSync("bash", ["-lc", `command -v ${cmd} >/dev/null 2>&1`]);
  return r.status === 0;
}

function runPdftoppmToPng(pdfAbsPath, pageNo, outPngPath, dpi = 200) {
  if (!hasCmd("pdftoppm")) {
    throw new Error(
      "pdftoppm not found. Install Poppler:\n  brew install poppler\nThen re-run."
    );
  }

  const outBase = outPngPath.replace(/\.png$/i, "");

  const r = spawnSync(
    "pdftoppm",
    ["-r", String(dpi), "-f", String(pageNo), "-l", String(pageNo), "-png", pdfAbsPath, outBase],
    { encoding: "utf8", maxBuffer: 50 * 1024 * 1024 }
  );

  if (r.status !== 0) {
    throw new Error(`pdftoppm failed: ${r.stderr || r.stdout || "unknown error"}`);
  }

  // Poppler output naming for single page: `${outBase}-1.png`
  const dir = path.dirname(outBase);
  const prefix = path.basename(outBase) + "-";
  const produced = fs
    .readdirSync(dir)
    .filter((f) => f.startsWith(prefix) && f.endsWith(".png"))
    .map((f) => path.join(dir, f))
    .sort();

  if (!produced.length) {
    throw new Error(`pdftoppm produced no PNGs with prefix: ${path.join(dir, prefix)}*.png`);
  }

  fs.renameSync(produced[0], outPngPath);

  for (let i = 1; i < produced.length; i++) {
    try { fs.unlinkSync(produced[i]); } catch (_) {}
  }
}

function runTesseractTSV(pngPath) {
  // Preserve column spacing + whitelist to help table numerics
  const args = [
  pngPath,
  "stdout",
  "-l", "eng+snum",
  "--oem", "1",
  "--psm", "6",
  "tsv",
  "-c", "preserve_interword_spaces=1",
];

  const r = spawnSync("tesseract", args, {
    encoding: "utf8",
    maxBuffer: 50 * 1024 * 1024,
  });

  if (r.status !== 0) {
    throw new Error(`tesseract failed: ${r.stderr || r.stdout || "unknown error"}`);
  }
  return r.stdout;
}

function parseTsv(tsv) {
  const lines = tsv.split(/\r?\n/).filter(Boolean);
  const out = [];
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split("\t");
    if (cols.length < 12) continue;

    const left = Number(cols[6]);
    const top = Number(cols[7]);
    const width = Number(cols[8]);
    const height = Number(cols[9]);
    const conf = Number(cols[10]);
    const text = (cols[11] || "").trim();

    if (!text) continue;
    if (!Number.isFinite(left) || !Number.isFinite(top)) continue;

    out.push({ str: text, x: left, y: top, w: width, h: height, conf, _ocr: true });
  }
  return out;
}

async function pageOcrItems(pdf, pageNo, opts = {}) {
  const pdfAbs = pdf.__pdfPathAbs;
  if (!pdfAbs) throw new Error("pdf.__pdfPathAbs missing; loadPdf() must set it.");

  const dpi = opts.dpi ?? opts.ocrDpi ?? 250;

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "satchart-ocr-"));
  const pngPath = path.join(tmpDir, `page_${pageNo}.png`);

  try {
    runPdftoppmToPng(pdfAbs, pageNo, pngPath, dpi);
    const tsv = runTesseractTSV(pngPath);
    return parseTsv(tsv);
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) {}
  }
}

function isDateToken(s) {
  return /^\d{1,2}\/\d{1,2}[a-z]?$/.test(String(s).trim());
}

function isNumberToken(s) {
  const t = String(s).trim();
  if (!t) return false;
  if (/^\d+$/.test(t)) return true;
  if (/^\d{1,3}([,\.]\d{3})+$/.test(t)) return true;
  if (/^\d{1,3}([,\.]\d{3})+[,\.\-]?$/.test(t)) return true;
  return false;
}

function countSignals(items) {
  const dates = items.filter(it => isDateToken(it.str)).length;
  const nums  = items.filter(it => isNumberToken(it.str)).length;
  return { dates, nums };
}

/**
 * Smart items:
 * - Get text items
 * - If text is missing table-like signals OR opts.forceOcr, OCR the page
 *
 * Supports both call styles:
 *   pageItemsSmart(pdf, pageNo, opts)
 *   pageItemsSmart(pdf, pdfPathIgnored, pageNo, opts)
 */
async function pageItemsSmart(pdf, a, b, c) {
  let pageNo, opts;

  if (typeof a === "number") {
    pageNo = a;
    opts = b || {};
  } else {
    // (pdf, pdfPathIgnored, pageNo, opts)
    pageNo = b;
    opts = c || {};
  }

  const forceOcr = !!opts.forceOcr;

  // Try text first unless forced
  if (!forceOcr) {
    const textItems = await pageTextItems(pdf, pageNo);
    const sig = countSignals(textItems);

    const minDates = opts.minDates ?? 5;
    const minNums = opts.minNums ?? 20;

    if (sig.dates >= minDates && sig.nums >= minNums) {
      return { items: textItems, mode: "text", sig };
    }
  }

  // OCR fallback (or forced)
  const ocrItems = await pageOcrItems(pdf, pageNo, {
    dpi: opts.ocrDpi ?? 300,
  });
  const sigO = countSignals(ocrItems);
  return { items: ocrItems, mode: "ocr", sig: sigO };
}

module.exports = {
  loadPdf,
  normalize,
  groupByLine,
  pageTextItems,
  pageOcrItems,
  pageItemsSmart,
};
/**
 * explode_nushagak_2021.js
 *
 * Takes the raw Nushagak 2021 pasted table (wrapped/condensed)
 * and rewrites it so every M/D token starts on its own line.
 *
 * Output: src/data/2021/raw/nushagak_exploded.txt
 */

const fs = require("fs");
const path = require("path");

const inPath = path.resolve("src/data/2021/raw/nushagak.txt");
const outPath = path.resolve("src/data/2021/raw/nushagak_exploded.txt");

if (!fs.existsSync(inPath)) {
  console.error("Missing:", inPath);
  process.exit(1);
}

let s = fs.readFileSync(inPath, "utf8");

// Normalize whitespace
s = s.replace(/\r/g, "");
s = s.replace(/[–—]/g, "-"); // normalize dash glyphs
s = s.replace(/\u00A0/g, " "); // nbsp -> space

// Drop obvious headers
s = s
  .split("\n")
  .filter(line => {
    const t = line.trim();
    if (!t) return false;
    if (/^Table\b/i.test(t)) return false;
    if (/continued/i.test(t)) return false;
    if (/^Hours fished/i.test(t)) return false;
    if (/^Date\b/i.test(t)) return false;
    return true;
  })
  .join(" ");

// IMPORTANT: explode so every M/D begins a new line
// - Handles 6/24, 7/1, 7/17, etc.
// - Ensures we don’t match years like 2021-07-17
// explode so every M/D (optionally followed by a footnote letter) begins a new line
// e.g. "7/17", "7/17b", "6/30a"
s = s.replace(/(\s|^)(\d{1,2}\/\d{1,2}[a-z]?)(?=\s)/gi, "\n$2");

// Cleanup
s = s
  .split("\n")
  .map(x => x.trim())
  .filter(Boolean)
  .join("\n")
  .trim() + "\n";

fs.writeFileSync(outPath, s, "utf8");
console.log("✅ wrote", outPath);

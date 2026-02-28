#!/usr/bin/env node

/**
 * normalize_old_registration.js
 *
 * Convert wide registration tables (2015–2019) like:
 *   date,naknek_kvichak_total,naknek_kvichak_dual,egegik_total,egegik_dual,...
 *
 * into normalized per-district files:
 *   src/data/YYYY/registration_YYYY.csv
 *
 * with header:
 *   date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes
 */

const fs = require("fs");
const path = require("path");

const YEARS = [2015, 2016, 2017, 2018, 2019];

const DISTRICTS = [
  { key: "naknek-kvichak", total: "naknek_kvichak_total", dual: "naknek_kvichak_dual" },
  { key: "egegik",         total: "egegik_total",         dual: "egegik_dual" },
  { key: "ugashik",        total: "ugashik_total",        dual: "ugashik_dual" },
  { key: "nushagak",       total: "nushagak_total",       dual: "nushagak_dual" },
  { key: "togiak",         total: "togiak_total",         dual: null }, // no dual column
];

function normalizeYear(year) {
  const inFile  = path.join("src", "data", String(year), "district_registration_" + year + ".csv");
  const outFile = path.join("src", "data", String(year), "registration_" + year + ".csv");

  if (!fs.existsSync(inFile)) {
    console.error("⚠️  Input not found for " + year + ": " + inFile);
    return;
  }

  const raw = fs.readFileSync(inFile, "utf8").trimEnd();
  const lines = raw.split(/\r?\n/);
  if (!lines.length) {
    console.error("⚠️  Empty file: " + inFile);
    return;
  }

  const header = lines[0].split(",");
  const dateIdx = header.indexOf("date");
  if (dateIdx !== 0) {
    console.error("⚠️  Unexpected header in " + inFile + " (date column not first). Got:");
    console.error("   " + header.join(","));
    return;
  }

  // Map each district to column indices
  for (const d of DISTRICTS) {
    d.totalIdx = header.indexOf(d.total);
    d.dualIdx  = d.dual ? header.indexOf(d.dual) : -1;

    if (d.totalIdx === -1) {
      console.error("⚠️  Missing column " + d.total + " in " + inFile + ". Skipping this year.");
      return;
    }
    if (d.dual && d.dualIdx === -1) {
      console.error("⚠️  Missing column " + d.dual + " in " + inFile + ". Skipping this year.");
      return;
    }
  }

  const outLines = [];
  outLines.push("date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes");

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    const cols = line.split(",");
    const date = cols[dateIdx];

    for (const d of DISTRICTS) {
      const totalStr = cols[d.totalIdx] || "";
      const dualStr  = d.dualIdx >= 0 ? cols[d.dualIdx] || "" : "0";

      const total = Number(totalStr);
      const dual  = Number(dualStr);

      // If there's no total and no dual, skip this district for this date
      if (!Number.isFinite(total) && !Number.isFinite(dual)) continue;

      const driftPermits = Number.isFinite(total) ? total : 0;
      const dualPermits  = Number.isFinite(dual)  ? dual  : 0;
      const driftBoats   = driftPermits - dualPermits;

      const row = [
        date,
        d.key,
        driftPermits,
        dualPermits,
        driftBoats,
        "",                    // flags
        "table10_registration" // notes
      ];
      outLines.push(row.join(","));
    }
  }

  fs.writeFileSync(outFile, outLines.join("\n") + "\n", "utf8");
  console.log("✅ Wrote normalized registration: " + outFile);
}

for (const year of YEARS) {
  normalizeYear(year);
}

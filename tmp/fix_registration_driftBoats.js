#!/usr/bin/env node

/**
 * Fix driftBoats in district registration CSVs for 2015–2019.
 *
 * Expected header:
 *   date,districtKey,driftPermits,dualPermits[,driftBoats],flags,notes
 *
 * For each row:
 *   driftBoats = driftPermits - dualPermits
 */

const fs = require("fs");
const path = require("path");

const YEARS = [2015, 2016, 2017, 2018, 2019];

function findRegistrationFile(year) {
  const baseDir = path.join("src", "data", String(year));
  const candidates = [
    path.join(baseDir, "registration_" + year + ".csv"),
    path.join(baseDir, "registration.csv"),
    path.join(baseDir, "district_registration_" + year + ".csv"),
    path.join(baseDir, "district_registration.csv"),
  ];
  for (const f of candidates) {
    if (fs.existsSync(f)) return f;
  }
  return null;
}

function fixFile(year) {
  const filename = findRegistrationFile(year);
  if (!filename) {
    console.error(
      "⚠️  No registration CSV found for " +
        year +
        " (tried registration_YYYY.csv and district_registration_YYYY.csv) — skipping"
    );
    return;
  }

  const raw = fs.readFileSync(filename, "utf8").trimEnd();
  const lines = raw.split(/\r?\n/);
  if (lines.length === 0) {
    console.error("⚠️  File empty: " + filename + " — skipping");
    return;
  }

  const header = lines[0].split(",");
  const dateIdx  = header.indexOf("date");
  const dkIdx    = header.indexOf("districtKey");
  const driftIdx = header.indexOf("driftPermits");
  const dualIdx  = header.indexOf("dualPermits");
  let   boatsIdx = header.indexOf("driftBoats");

  if (dateIdx !== 0 || dkIdx !== 1 || driftIdx === -1 || dualIdx === -1) {
    console.error("⚠️  Unexpected header in " + filename + ". Please check it manually.");
    console.error("   Header:", header.join(","));
    return;
  }

  // If driftBoats is missing, insert it right before "flags"
  if (boatsIdx === -1) {
    const flagsIdx = header.indexOf("flags");
    if (flagsIdx === -1) {
      console.error(
        "⚠️  No driftBoats column and no flags column in " +
          filename +
          ". Check header."
      );
      return;
    }
    boatsIdx = flagsIdx;
    header.splice(boatsIdx, 0, "driftBoats");
  }

  const outLines = [];
  outLines.push(header.join(","));

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    const cols = line.split(",");

    // Pad columns if driftBoats was just inserted
    while (cols.length < header.length) cols.push("");

    const driftPermits = Number(cols[driftIdx]);
    const dualPermits  = Number(cols[dualIdx]);

    let driftBoats = "";
    if (Number.isFinite(driftPermits) && Number.isFinite(dualPermits)) {
      driftBoats = driftPermits - dualPermits;
    }

    cols[boatsIdx] = driftBoats === "" ? "" : String(driftBoats);
    outLines.push(cols.join(","));
  }

  const newCsv = outLines.join("\n") + "\n";
  fs.writeFileSync(filename, newCsv, "utf8");
  console.log("✅ Fixed driftBoats in " + filename);
}

for (const year of YEARS) {
  fixFile(year);
}

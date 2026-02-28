# AGENTS.md — SatChart / Deep Research

## Project Overview

SatChart is a fisheries analytics app for Bristol Bay.

This repository contains:
- ETL pipeline for Fisheries Management Reports (FMR)
- Offline SQLite build system
- District/day-level operational data
- Deep Research SwiftUI analytics interface

The iOS app consumes the built offline.sqlite pack.

---

## Core Architecture

### Data Flow

FMR PDFs → CSV parsing → src/data/YYYY → build_offline_sqlite.py → offline.sqlite → manifest.json → iOS app

### District Keys

Must exactly match SQLite:
- naknek_kvichak
- egegik
- ugashik
- nushagak
- togiak

Never change district key naming.

---

## Deep Research UI Rules

### Season Windows

Default window:
06/12 – 08/03

Togiak override:
06/17 – 08/20

Do not alter other districts.

---

### July 17 Registration Cutoff

After 07/16:
- Drift Registration = dashed
- Cumulative Boat-Hours = dashed
- Sockeye/Boat TD = dashed
- Sockeye/Drift Boat = dashed (bar rule marks)
- Sockeye/Boat-Hour = dashed (bar rule marks)

Dashed indicates modeled / estimated values.

---

### Togiak 2020 Confidential Handling

From 07/18–08/28:
285,800 sockeye confidential.

Current behavior:
- Distributed evenly 07/18–08/20
- Cumulative line remains linear
- Marked as estimated
- Efficiency metrics flagged

Do NOT:
- Backfill daily harvest with fake values
- Modify raw reported data

---

## Modeling Rules (Post-7/17 Drift Boats)

Future model will estimate ACTIVE drift boats using:

Window: 07/10–07/16 baseline

Metrics:
- Drift boats
- Drift deliveries
- Deliveries per boat
- Drift open hours
- Drift sockeye per day

Model must:
- Estimate active boats only
- Not alter historical registration data
- Only affect post-07/16 rendering

---

## Safety Rules

Agents must:

- Never modify raw CSV source data without explicit instruction.
- Never rename district keys.
- Never change SQLite schema without documenting it.
- Never alter manifest versioning logic unless instructed.
- Always preserve reproducibility of offline.sqlite builds.

---

## Build Commands

Rebuild offline pack:

python3 scripts/build_offline_sqlite.py

Deploy:

firebase deploy

Nuke simulator app:

xcrun simctl uninstall booted com.curraghfisheries.Bristol-Bay-Sandbars

---

## Coding Standards

Swift:
- Keep Chart builders simple
- Precompute chart points outside Chart { } blocks
- Avoid deeply nested Chart logic
- Use ISO date comparisons for cutoff logic

TypeScript:
- Loaders must be idempotent
- No mutation of original parsed arrays

Python:
- Build scripts must be deterministic
- No hidden randomness

---

## What Agents Should Help With

- Refactoring Chart rendering logic
- Modeling post-registration boat counts
- Detecting data anomalies
- Performance improvements
- Reducing SwiftUI compile-time complexity

---

## What Agents Should NOT Do

- Rewrite entire UI files without instruction
- Modify data model assumptions
- Change fisheries logic without domain review
- Simplify logic in ways that hide fishery nuance

---

This is a data-critical commercial fisheries analytics system.
Accuracy > elegance.

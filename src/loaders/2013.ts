import { YearBatch } from "../batchValidation";

type PermitsRow2013 = {
  nk: number; nkDual: number;
  e: number;  eDual: number;
  u: number;  uDual: number;
  n: number;  nDual: number;
  t: number;  // dual not permitted in Togiak
};

// FMR14-23 Table 13 (6/25–7/16)
const permitsByDate: Record<string, PermitsRow2013> = {
  "2013-06-25": { nk: 471, nkDual: 31, e: 369, eDual: 36, u: 362, uDual: 48, n: 354, nDual: 53, t: 35 },

  "2013-06-26": { nk: 487, nkDual: 74, e: 379, eDual: 64, u: 328, uDual: 94, n: 359, nDual: 57, t: 39 },
  "2013-06-27": { nk: 489, nkDual: 79, e: 372, eDual: 67, u: 277, uDual: 83, n: 363, nDual: 58, t: 49 },
  "2013-06-28": { nk: 505, nkDual: 79, e: 378, eDual: 64, u: 231, uDual: 67, n: 369, nDual: 58, t: 53 },
  "2013-06-29": { nk: 559, nkDual: 83, e: 385, eDual: 70, u: 234, uDual: 49, n: 371, nDual: 62, t: 53 },
  "2013-06-30": { nk: 601, nkDual: 100, e: 399, eDual: 73, u: 235, uDual: 49, n: 372, nDual: 60, t: 53 },

  "2013-07-01": { nk: 608, nkDual: 113, e: 399, eDual: 78, u: 227, uDual: 49, n: 359, nDual: 61, t: 54 },
  "2013-07-02": { nk: 610, nkDual: 115, e: 399, eDual: 78, u: 215, uDual: 47, n: 339, nDual: 58, t: 57 },
  "2013-07-03": { nk: 622, nkDual: 115, e: 395, eDual: 78, u: 217, uDual: 43, n: 326, nDual: 52, t: 58 },
  "2013-07-04": { nk: 634, nkDual: 117, e: 390, eDual: 80, u: 216, uDual: 44, n: 319, nDual: 49, t: 58 },
  "2013-07-05": { nk: 661, nkDual: 119, e: 379, eDual: 77, u: 219, uDual: 44, n: 316, nDual: 48, t: 58 },

  "2013-07-06": { nk: 669, nkDual: 127, e: 380, eDual: 75, u: 206, uDual: 45, n: 313, nDual: 48, t: 63 },
  "2013-07-07": { nk: 641, nkDual: 130, e: 361, eDual: 76, u: 208, uDual: 43, n: 319, nDual: 48, t: 70 },
  "2013-07-08": { nk: 635, nkDual: 122, e: 358, eDual: 70, u: 206, uDual: 43, n: 324, nDual: 50, t: 73 },
  "2013-07-09": { nk: 645, nkDual: 119, e: 366, eDual: 68, u: 186, uDual: 44, n: 338, nDual: 49, t: 75 },

  "2013-07-10": { nk: 668, nkDual: 120, e: 346, eDual: 70, u: 176, uDual: 41, n: 263, nDual: 50, t: 79 },
  "2013-07-11": { nk: 703, nkDual: 128, e: 332, eDual: 71, u: 177, uDual: 40, n: 241, nDual: 37, t: 79 },

  "2013-07-12": { nk: 786, nkDual: 137, e: 331, eDual: 69, u: 181, uDual: 41, n: 245, nDual: 33, t: 80 },
  "2013-07-13": { nk: 793, nkDual: 148, e: 334, eDual: 69, u: 201, uDual: 42, n: 248, nDual: 36, t: 81 },

  "2013-07-14": { nk: 792, nkDual: 146, e: 332, eDual: 73, u: 212, uDual: 47, n: 245, nDual: 37, t: 81 },
  "2013-07-15": { nk: 794, nkDual: 145, e: 337, eDual: 70, u: 205, uDual: 48, n: 251, nDual: 35, t: 81 },
  "2013-07-16": { nk: 810, nkDual: 144, e: 337, eDual: 71, u: 207, uDual: 46, n: 252, nDual: 36, t: 81 },
};

function permitsFor(
  date: string,
  districtKey: "naknek-kvichak" | "egegik" | "ugashik" | "nushagak" | "togiak"
) {
  const row = permitsByDate[date];
  if (!row) return { driftPermits: 0, dualPermits: 0 };

  switch (districtKey) {
    case "naknek-kvichak": return { driftPermits: row.nk, dualPermits: row.nkDual };
    case "egegik":         return { driftPermits: row.e,  dualPermits: row.eDual };
    case "ugashik":        return { driftPermits: row.u,  dualPermits: row.uDual };
    case "nushagak":       return { driftPermits: row.n,  dualPermits: row.nDual };
    case "togiak":         return { driftPermits: row.t,  dualPermits: 0 };
  }
}

function mkOps(
  year: number,
  date: string,
  districtKey: "naknek-kvichak" | "egegik" | "ugashik" | "nushagak" | "togiak",
  driftOpenHours: number,
  setOpenHours: number,
  totalCatch: number | null,
  sockeyeCatch: number | null,
  notes?: string[]
) {
  const { driftPermits, dualPermits } = permitsFor(date, districtKey);
  const driftBoats = driftPermits - dualPermits;

  return {
    year,
    date,
    districtKey,
    driftOpenHours,
    setOpenHours,
    driftPermits,
    dualPermits,
    driftBoats,
    catch: { total: totalCatch, sockeye: sockeyeCatch },
    ...(notes ? { notes } : {}),
  };
}

export async function load2013(): Promise<YearBatch> {
  const year = 2013;

  return {
    meta: {
      year,
      togiakOutsiderOpenDate: "2013-07-27",
      togiakOutsiderOpenReason: "fixed_date",
      allocationEndDate: "2013-07-17",
    },

    forecasts: [],

    // Seed ops rows (one per district) so validation passes.
    // These are real values from the 2013 district tables for 6/25:
    // NK Table 7, Egegik Table 10, Ugashik Table 14, Nushagak Table 19, Togiak Table 21.
    
    ops: [
  // -------------------------
  // NAKNEK-KVICHAK (Table 7) — 2013-06-25 to 2013-07-16
  // -------------------------
  mkOps(year, "2013-06-25", "naknek-kvichak", 6,   7,    223035, 220843, ["drift_naknek_section_only"]),
  mkOps(year, "2013-06-26", "naknek-kvichak", 6.5, 7.5,  386672, 385527, ["drift_naknek_section_only"]),
  mkOps(year, "2013-06-27", "naknek-kvichak", 5.5, 6.5,  453791, 451557, ["drift_naknek_section_only"]),
  mkOps(year, "2013-06-28", "naknek-kvichak", 6.5, 7.5,  363547, 362647, ["drift_naknek_section_only"]),
  mkOps(year, "2013-06-29", "naknek-kvichak", 7,   7.5,  320783, 319443, ["drift_naknek_section_only"]),

  // Drift hours shown as "7.0/7.5" — store first value (7.0)
  mkOps(year, "2013-06-30", "naknek-kvichak", 7.0, 24,   380361, 378833, ["drift_naknek_section_only", "drift_hours_slash_used_first_value"]),

  // Drift hours shown as "7.5/7.5" — store first value (7.5)
  mkOps(year, "2013-07-01", "naknek-kvichak", 7.5, 24,   362393, 360437, ["drift_naknek_section_only", "drift_hours_slash_used_first_value"]),

  mkOps(year, "2013-07-02", "naknek-kvichak", 7.5, 15.5, 252236, 249834, ["drift_naknek_section_only"]),
  mkOps(year, "2013-07-03", "naknek-kvichak", 7.5, 7.5,  253669, 251799, ["drift_naknek_section_only"]),
  mkOps(year, "2013-07-04", "naknek-kvichak", 7,   8,    179888, 178100, ["drift_naknek_section_only"]),

  // 7/05–7/09 blank in Table 7 — treat as closed
  mkOps(year, "2013-07-05", "naknek-kvichak", 0,   0,    0,      0),
  mkOps(year, "2013-07-06", "naknek-kvichak", 0,   0,    0,      0),
  mkOps(year, "2013-07-07", "naknek-kvichak", 0,   0,    0,      0),
  mkOps(year, "2013-07-08", "naknek-kvichak", 0,   0,    0,      0),
  mkOps(year, "2013-07-09", "naknek-kvichak", 0,   0,    0,      0),

  mkOps(year, "2013-07-10", "naknek-kvichak", 7,   10,   489631, 413514, ["drift_naknek_section_only"]),

  // Drift hours shown as "7.5/7" — store first value (7.5)
  mkOps(year, "2013-07-11", "naknek-kvichak", 7.5, 24,   120013, 71875,  ["drift_naknek_section_only", "drift_hours_slash_used_first_value"]),

  // Drift hours shown as "8.5/7" — store first value (8.5)
  mkOps(year, "2013-07-12", "naknek-kvichak", 8.5, 24,   115552, 84842,  ["drift_naknek_section_only", "drift_hours_slash_used_first_value"]),

  // Drift hours shown as "8.5/7" — store first value (8.5)
  mkOps(year, "2013-07-13", "naknek-kvichak", 8.5, 24,    67828, 55156,  ["drift_naknek_section_only", "drift_hours_slash_used_first_value"]),

  // Drift hours shown as "8.5/7.5" — store first value (8.5)
  mkOps(year, "2013-07-14", "naknek-kvichak", 8.5, 24,    39956, 30847,  ["drift_hours_slash_used_first_value"]),

  // Drift hours shown as "8/7.5" — store first value (8)
  mkOps(year, "2013-07-15", "naknek-kvichak", 8,   24,    29481, 20144,  ["drift_hours_slash_used_first_value"]),

  // Drift hours shown as "7/4.5" — store first value (7)
  mkOps(year, "2013-07-16", "naknek-kvichak", 7,   24,    21336, 12701,  ["drift_hours_slash_used_first_value"]),


  // -------------------------
  // EGEGIK (Table 10) — 2013-06-25 to 2013-07-16
  // NOTE: 2013-06-26 and 2013-07-05 omitted because hours were not fully captured in your pasted text.
  // -------------------------
  mkOps(year, "2013-06-25", "egegik", 5,   8,     216175, 213472),

  mkOps(year, "2013-06-28", "egegik", 4,   7.75,  374044, 372813),
  mkOps(year, "2013-06-29", "egegik", 6.5, 14.5,  331277, 330249),
  mkOps(year, "2013-06-30", "egegik", 14,  9.25,  566882, 564736),

  mkOps(year, "2013-07-01", "egegik", 10,  8,     433102, 430621),
  mkOps(year, "2013-07-02", "egegik", 4,   8,     233845, 232559),
  mkOps(year, "2013-07-03", "egegik", 4,   8,     126824, 124661),

  mkOps(year, "2013-07-08", "egegik", 5,   8,      97526,  94914),
  mkOps(year, "2013-07-09", "egegik", 6,   8,     214525, 211671),
  mkOps(year, "2013-07-10", "egegik", 6,   8,      56241,  54372),
  mkOps(year, "2013-07-11", "egegik", 6,   8,      89934,  87240),

  mkOps(year, "2013-07-12", "egegik", 6,   24,     75454,  72313),
  mkOps(year, "2013-07-13", "egegik", 6,   24,     42300,  40632),
  mkOps(year, "2013-07-14", "egegik", 12,  24,     21464,  20198),
  mkOps(year, "2013-07-15", "egegik", 24,  24,     23017,  21516),
  mkOps(year, "2013-07-16", "egegik", 24,  24,     14001,  13018),


  // -------------------------
  // UGASHIK (Table 14) — 2013-06-25 to 2013-07-16
  // -------------------------
  mkOps(year, "2013-06-25", "ugashik", 8,   12,   341707, 340278),
  // 6/26: you said hours were not listed -> preserve catch, don’t infer hours
  mkOps(year, "2013-06-26", "ugashik", 0,   0,    171394, 170385, ["hours_not_reported_in_table"]),
  mkOps(year, "2013-06-27", "ugashik", 10,  40,    10042,   9483),

  mkOps(year, "2013-06-29", "ugashik", 6,   9.5,  206146, 204833),
  mkOps(year, "2013-07-01", "ugashik", 7,   10,   187419, 185788),

  // 7/02 set-only 9 hrs
  mkOps(year, "2013-07-02", "ugashik", 0,   9,     11685,  10749, ["set_only"]),
  // 7/05 existed (total 214753) but hours not listed -> keep, flag unknown
  mkOps(year, "2013-07-05", "ugashik", 0,   0,    214753, 214753, ["hours_not_reported_in_table"]),
  // 7/06 set-only 12 hrs
  mkOps(year, "2013-07-06", "ugashik", 0,   12,    13854,  12743, ["set_only"]),

  mkOps(year, "2013-07-10", "ugashik", 5,   9,     92713,  89746),
  mkOps(year, "2013-07-11", "ugashik", 7,   9,     57437,  52535),
  mkOps(year, "2013-07-12", "ugashik", 8.5, 9,     42064,  39516),
  mkOps(year, "2013-07-13", "ugashik", 10,  10.5,  34042,  31633),
  mkOps(year, "2013-07-14", "ugashik", 12,  24,    22805,  21107),
  mkOps(year, "2013-07-15", "ugashik", 24,  24,    17722,  16459),
  mkOps(year, "2013-07-16", "ugashik", 24,  24,    13629,  12649),


  // -------------------------
  // NUSHAGAK (Table 19) — 2013-06-25 to 2013-07-16
  // driftOpenHours = max(Nush drift, Igush drift)
  // setOpenHours   = max(Nush set,   Igush set)
  // -------------------------
  mkOps(year, "2013-06-25", "nushagak", 16, 24, 246164, 205936, ["hours_max_across_sections"]),
  mkOps(year, "2013-06-26", "nushagak", 18, 24, 393641, 325972, ["hours_max_across_sections"]),
  mkOps(year, "2013-06-27", "nushagak", 16, 24, 395733, 351934, ["hours_max_across_sections"]),
  mkOps(year, "2013-06-28", "nushagak", 16, 24, 283986, 256743, ["hours_max_across_sections"]),
  mkOps(year, "2013-06-29", "nushagak", 16, 24, 242945, 207947, ["hours_max_across_sections"]),
  mkOps(year, "2013-06-30", "nushagak", 16, 24, 273370, 245251, ["hours_max_across_sections"]),

  mkOps(year, "2013-07-01", "nushagak", 20, 24, 125215, 108317, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-02", "nushagak", 17, 24, 166153, 142982, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-03", "nushagak", 17, 24, 210866, 178313, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-04", "nushagak", 17, 24, 171703, 148366, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-05", "nushagak", 19, 24, 111324,  95823, ["hours_max_across_sections"]),

  mkOps(year, "2013-07-06", "nushagak", 24, 24, 131829, 106939, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-07", "nushagak", 24, 24,  82670,  69698, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-08", "nushagak", 24, 24,  78436,  64268, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-09", "nushagak", 24, 24,  56085,  44620, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-10", "nushagak", 24, 24,  60437,  48459, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-11", "nushagak", 24, 24,  30372,  23958, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-12", "nushagak", 24, 24,  24536,  19735, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-13", "nushagak", 24, 24,  19660,  14846, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-14", "nushagak", 24, 24,  14397,  10552, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-15", "nushagak", 24, 24,  11364,   8489, ["hours_max_across_sections"]),
  mkOps(year, "2013-07-16", "nushagak", 24, 24,   6129,   3891, ["hours_max_across_sections"]),


  // -------------------------
  // TOGIAK (Table 21) — 2013-06-25 to 2013-07-16
  // Note: hours not reported in Table 21; assumed 24/24 for display consistency.
  // -------------------------
  mkOps(year, "2013-06-25", "togiak", 24, 24, 18929, 15638, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-06-26", "togiak", 24, 24,  5368,  3227, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-06-27", "togiak", 24, 24,  1686,   394, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-06-28", "togiak", 24, 24,  2835,   967, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-06-29", "togiak", 24, 24,   127,    60, ["togiak_hours_not_reported_assumed_24"]),

  mkOps(year, "2013-07-01", "togiak", 24, 24, 14221,  8779, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-02", "togiak", 24, 24, 17228, 11226, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-03", "togiak", 24, 24, 18630, 12097, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-04", "togiak", 24, 24, 21381, 15145, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-05", "togiak", 24, 24, 32592, 22331, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-06", "togiak", 24, 24, 26438, 17889, ["togiak_hours_not_reported_assumed_24"]),

  mkOps(year, "2013-07-08", "togiak", 24, 24, 33259, 25559, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-09", "togiak", 24, 24, 52021, 35991, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-10", "togiak", 24, 24, 53608, 34864, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-11", "togiak", 24, 24, 35902, 23511, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-12", "togiak", 24, 24, 28130, 21692, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-13", "togiak", 24, 24, 24357, 18243, ["togiak_hours_not_reported_assumed_24"]),

  mkOps(year, "2013-07-15", "togiak", 24, 24, 32861, 18774, ["togiak_hours_not_reported_assumed_24"]),
  mkOps(year, "2013-07-16", "togiak", 24, 24, 29650, 15722, ["togiak_hours_not_reported_assumed_24"]),

  ],

  rivers: [
  // =========================
  // EASTSIDE TOWERS — 2013
  // Source: FMR 14-23 Table 8
  // Blank cells = no data collected (no row)
  // =========================

  // ---- KVICHAK ----
  
  { year, date: "2013-06-21", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 894, cumulativeEscapement: 894 },
  { year, date: "2013-06-22", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 60, cumulativeEscapement: 954 },
  { year, date: "2013-06-23", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 11628, cumulativeEscapement: 12582 },
  { year, date: "2013-06-24", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 55410, cumulativeEscapement: 67992 },
  { year, date: "2013-06-25", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 54684, cumulativeEscapement: 122676 },
  { year, date: "2013-06-26", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 24042, cumulativeEscapement: 146718 },
  { year, date: "2013-06-27", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 44574, cumulativeEscapement: 191292 },
  { year, date: "2013-06-28", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 71028, cumulativeEscapement: 262320 },
  { year, date: "2013-06-29", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 132828, cumulativeEscapement: 395148 },
  { year, date: "2013-06-30", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 142530, cumulativeEscapement: 537678 },
  { year, date: "2013-07-01", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 169140, cumulativeEscapement: 706818 },
  { year, date: "2013-07-02", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 304596, cumulativeEscapement: 1011414 },
  { year, date: "2013-07-03", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 318012, cumulativeEscapement: 1329426 },
  { year, date: "2013-07-04", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 154824, cumulativeEscapement: 1484250 },
  { year, date: "2013-07-05", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 86376, cumulativeEscapement: 1570626 },
  { year, date: "2013-07-06", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 22992, cumulativeEscapement: 1593618 },
  { year, date: "2013-07-07", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 22500, cumulativeEscapement: 1616118 },
  { year, date: "2013-07-08", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 14682, cumulativeEscapement: 1630800 },
  { year, date: "2013-07-09", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 78444, cumulativeEscapement: 1709244 },
  { year, date: "2013-07-10", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 232362, cumulativeEscapement: 1941606 },
  { year, date: "2013-07-11", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 117126, cumulativeEscapement: 2058732 },
  { year, date: "2013-07-12", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 23538, cumulativeEscapement: 2082270 },
  { year, date: "2013-07-13", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 3306, cumulativeEscapement: 2085576 },
  { year, date: "2013-07-14", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 2100, cumulativeEscapement: 2087676 },
  { year, date: "2013-07-15", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 900, cumulativeEscapement: 2088576 },

  // ---- NAKNEK ----
  { year, date: "2013-06-20", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 9090, cumulativeEscapement: 9090 },
  { year, date: "2013-06-21", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 14886, cumulativeEscapement: 23976 },
  { year, date: "2013-06-22", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 41880, cumulativeEscapement: 65856 },
  { year, date: "2013-06-23", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 54744, cumulativeEscapement: 120600 },
  { year, date: "2013-06-24", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 26028, cumulativeEscapement: 146628 },
  { year, date: "2013-06-25", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 10446, cumulativeEscapement: 157074 },
  { year, date: "2013-06-26", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 20766, cumulativeEscapement: 177840 },
  { year, date: "2013-06-27", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 59808, cumulativeEscapement: 237648 },
  { year, date: "2013-06-28", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 93060, cumulativeEscapement: 330708 },
  { year, date: "2013-06-29", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 76788, cumulativeEscapement: 407496 },
  { year, date: "2013-06-30", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 59202, cumulativeEscapement: 466698 },
  { year, date: "2013-07-01", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 21042, cumulativeEscapement: 487740 },
  { year, date: "2013-07-02", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 17658, cumulativeEscapement: 505398 },
  { year, date: "2013-07-03", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 24660, cumulativeEscapement: 530058 },
  { year, date: "2013-07-04", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 17472, cumulativeEscapement: 547530 },
  { year, date: "2013-07-05", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 13812, cumulativeEscapement: 561342 },
  { year, date: "2013-07-06", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 12906, cumulativeEscapement: 574248 },
  { year, date: "2013-07-07", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 103038, cumulativeEscapement: 677286 },
  { year, date: "2013-07-08", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 92448, cumulativeEscapement: 769734 },
  { year, date: "2013-07-09", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 109812, cumulativeEscapement: 879546 },
  { year, date: "2013-07-10", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 97584, cumulativeEscapement: 1071582 },
  { year, date: "2013-07-11", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 26622, cumulativeEscapement: 1098204 },
  { year, date: "2013-07-12", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 11082, cumulativeEscapement: 1109286 },
  { year, date: "2013-07-13", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 3042, cumulativeEscapement: 1112328 },
  { year, date: "2013-07-14", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 1302, cumulativeEscapement: 1113630 },

  // ---- EGEGIK ----
  { year, date: "2013-06-18", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 44892, cumulativeEscapement: 44892 },
  { year, date: "2013-06-19", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 92394, cumulativeEscapement: 137286 },
  { year, date: "2013-06-21", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 47484, cumulativeEscapement: 230136 },
  { year, date: "2013-06-22", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 40314, cumulativeEscapement: 270450 },
  { year, date: "2013-06-23", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 72648, cumulativeEscapement: 343098 },
  { year, date: "2013-06-24", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 14952, cumulativeEscapement: 358050 },
  { year, date: "2013-06-25", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 44502, cumulativeEscapement: 402552 },
  { year, date: "2013-06-26", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 2814, cumulativeEscapement: 405366 },
  { year, date: "2013-06-27", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 19326, cumulativeEscapement: 424692 },
  { year, date: "2013-06-28", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 89592, cumulativeEscapement: 514284 },
  { year, date: "2013-06-29", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 89238, cumulativeEscapement: 603522 },
  { year, date: "2013-06-30", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 86610, cumulativeEscapement: 690132 },
  { year, date: "2013-07-01", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 8346, cumulativeEscapement: 698478 },
  { year, date: "2013-07-02", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 19776, cumulativeEscapement: 718254 },
  { year, date: "2013-07-03", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 35982, cumulativeEscapement: 754236 },
  { year, date: "2013-07-04", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 17010, cumulativeEscapement: 771246 },
  { year, date: "2013-07-05", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 19404, cumulativeEscapement: 790650 },
  { year, date: "2013-07-06", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 17046, cumulativeEscapement: 807696 },
  { year, date: "2013-07-07", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 6204, cumulativeEscapement: 813900 },
  { year, date: "2013-07-08", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 41448, cumulativeEscapement: 855348 },
  { year, date: "2013-07-09", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 118650, cumulativeEscapement: 973998 },

  // ---- UGASHIK ----
  { year, date: "2013-06-27", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 10734, cumulativeEscapement: 10734 },
  { year, date: "2013-06-28", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 37152, cumulativeEscapement: 47886 },
  { year, date: "2013-06-29", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 24924, cumulativeEscapement: 72810 },
  { year, date: "2013-06-30", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 25800, cumulativeEscapement: 98610 },
  { year, date: "2013-07-01", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 25200, cumulativeEscapement: 123810 },
  { year, date: "2013-07-02", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 9342, cumulativeEscapement: 133152 },
  { year, date: "2013-07-03", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 8382, cumulativeEscapement: 141534 },
  { year, date: "2013-07-04", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 19590, cumulativeEscapement: 161124 },
  { year, date: "2013-07-05", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 29418, cumulativeEscapement: 190542 },
  { year, date: "2013-07-06", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 24876, cumulativeEscapement: 215418 },
  { year, date: "2013-07-07", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 23742, cumulativeEscapement: 239160 },
  { year, date: "2013-07-08", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 22104, cumulativeEscapement: 261264 },
  { year, date: "2013-07-09", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 21630, cumulativeEscapement: 282894 },
  { year, date: "2013-07-10", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 41784, cumulativeEscapement: 324678 },
  { year, date: "2013-07-11", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 81726, cumulativeEscapement: 406404 },
  { year, date: "2013-07-12", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 135738, cumulativeEscapement: 542142 },
  { year, date: "2013-07-13", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 107604, cumulativeEscapement: 649746 },
  { year, date: "2013-07-14", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 74286, cumulativeEscapement: 724032 },
  { year, date: "2013-07-15", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 39102, cumulativeEscapement: 763134 },
  { year, date: "2013-07-16", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 27822, cumulativeEscapement: 790956 },
  { year, date: "2013-07-17", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 16290, cumulativeEscapement: 807246 },
  { year, date: "2013-07-18", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 8496, cumulativeEscapement: 815742 },
  { year, date: "2013-07-19", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 13320, cumulativeEscapement: 829062 },
  { year, date: "2013-07-20", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 10782, cumulativeEscapement: 839844 },
  { year, date: "2013-07-21", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 8640, cumulativeEscapement: 848484 },
  { year, date: "2013-07-22", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 10692, cumulativeEscapement: 859176 },
  { year, date: "2013-07-23", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 14208, cumulativeEscapement: 873384 },
  { year, date: "2013-07-24", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 10530, cumulativeEscapement: 883914 },
  { year, date: "2013-07-25", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 8358, cumulativeEscapement: 892272 },
  { year, date: "2013-07-26", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 5838, cumulativeEscapement: 898110 },
],
  };
}
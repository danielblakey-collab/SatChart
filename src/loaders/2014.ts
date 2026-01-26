import { YearBatch } from "../batchValidation";

type PermitsRow2014 = {
  nk: number; nkDual: number;
  e: number;  eDual: number;
  u: number;  uDual: number;
  n: number;  nDual: number;
  t: number; // no dual in Togiak
};

const permitsByDate: Record<string, PermitsRow2014> = {
  "2014-06-25": { nk: 557, nkDual: 95,  e: 452, eDual: 80,  u: 17,  uDual: 1,  n: 586, nDual: 119, t: 57 },
  "2014-06-26": { nk: 566, nkDual: 95,  e: 459, eDual: 83,  u: 20,  uDual: 1,  n: 584, nDual: 118, t: 59 },
  "2014-06-27": { nk: 573, nkDual: 96,  e: 462, eDual: 85,  u: 19,  uDual: 1,  n: 590, nDual: 119, t: 59 },
  "2014-06-28": { nk: 581, nkDual: 98,  e: 462, eDual: 85,  u: 20,  uDual: 1,  n: 558, nDual: 109, t: 59 },
  "2014-06-29": { nk: 581, nkDual: 97,  e: 449, eDual: 84,  u: 22,  uDual: 1,  n: 537, nDual: 105, t: 60 },
  "2014-06-30": { nk: 604, nkDual: 104, e: 423, eDual: 76,  u: 22,  uDual: 1,  n: 456, nDual: 79,  t: 61 },

  "2014-07-01": { nk: 617, nkDual: 105, e: 390, eDual: 65,  u: 38,  uDual: 5,  n: 432, nDual: 74,  t: 61 },
  "2014-07-02": { nk: 702, nkDual: 133, e: 390, eDual: 65,  u: 80,  uDual: 15, n: 419, nDual: 72,  t: 61 },
  "2014-07-03": { nk: 737, nkDual: 142, e: 376, eDual: 65,  u: 110, uDual: 25, n: 407, nDual: 67,  t: 61 },
  "2014-07-04": { nk: 749, nkDual: 143, e: 376, eDual: 65,  u: 110, uDual: 25, n: 402, nDual: 67,  t: 61 },
  "2014-07-05": { nk: 773, nkDual: 147, e: 375, eDual: 65,  u: 109, uDual: 24, n: 401, nDual: 67,  t: 62 },
  "2014-07-06": { nk: 807, nkDual: 152, e: 373, eDual: 69,  u: 111, uDual: 24, n: 365, nDual: 57,  t: 62 },
  "2014-07-07": { nk: 852, nkDual: 166, e: 320, eDual: 56,  u: 113, uDual: 25, n: 359, nDual: 55,  t: 63 },
  "2014-07-08": { nk: 812, nkDual: 155, e: 369, eDual: 69,  u: 131, uDual: 29, n: 344, nDual: 52,  t: 65 },
  "2014-07-09": { nk: 839, nkDual: 162, e: 345, eDual: 65,  u: 143, uDual: 29, n: 318, nDual: 44,  t: 66 },
  "2014-07-10": { nk: 841, nkDual: 155, e: 335, eDual: 66,  u: 150, uDual: 31, n: 285, nDual: 37,  t: 66 },
  "2014-07-11": { nk: 785, nkDual: 143, e: 341, eDual: 70,  u: 168, uDual: 34, n: 261, nDual: 34,  t: 69 },
  "2014-07-12": { nk: 806, nkDual: 148, e: 322, eDual: 70,  u: 205, uDual: 44, n: 255, nDual: 34,  t: 69 },
  "2014-07-13": { nk: 840, nkDual: 156, e: 314, eDual: 68,  u: 252, uDual: 47, n: 248, nDual: 31,  t: 70 },
  "2014-07-14": { nk: 872, nkDual: 162, e: 293, eDual: 62,  u: 241, uDual: 45, n: 250, nDual: 31,  t: 70 },
  "2014-07-15": { nk: 875, nkDual: 160, e: 297, eDual: 66,  u: 227, uDual: 41, n: 251, nDual: 32,  t: 71 },
  "2014-07-16": { nk: 876, nkDual: 159, e: 299, eDual: 66,  u: 229, uDual: 42, n: 253, nDual: 32,  t: 71 },
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

export async function load2014(): Promise<YearBatch> {
  const year = 2014;

  return {
    meta: {
      year,
      togiakOutsiderOpenDate: "2014-07-27",
      togiakOutsiderOpenReason: "fixed_date",
      allocationEndDate: "2014-07-17",
    },

    forecasts: [],

    ops: [
      // NAKNEK-KVICHAK (Table 7) — 2014-06-25..2014-07-16
      mkOps(year, "2014-06-25", "naknek-kvichak", 14.5, 16.5,  586642,  585119, ["drift_naknek_section_only"]),
      mkOps(year, "2014-06-26", "naknek-kvichak", 16,   18.5,  678848,  676372, ["drift_naknek_section_only"]),
      mkOps(year, "2014-06-27", "naknek-kvichak", 16,   19,   1139846, 1136933, ["drift_naknek_section_only"]),
      mkOps(year, "2014-06-28", "naknek-kvichak", 7.5,  7.5,   725024,  723834, ["drift_naknek_section_only"]),
      mkOps(year, "2014-06-29", "naknek-kvichak", 7.5,  7,     385988,  385257, ["drift_naknek_section_only"]),
      mkOps(year, "2014-06-30", "naknek-kvichak", 8,    7,     735665,  733533),
      mkOps(year, "2014-07-01", "naknek-kvichak", 16,   19.5,  658810,  657656, ["drift_naknek_section_only"]),
      mkOps(year, "2014-07-02", "naknek-kvichak", 16.5, 20,    910710,  908217, ["drift_naknek_section_only_one_of_two_periods"]),
      mkOps(year, "2014-07-03", "naknek-kvichak", 13.5, 24,   1169066, 1166646, ["drift_naknek_section_only_one_of_two_periods"]),
      mkOps(year, "2014-07-04", "naknek-kvichak", 13.5, 24,   1190418, 1186796),
      mkOps(year, "2014-07-05", "naknek-kvichak", 13.5, 24,    951152,  947074),
      mkOps(year, "2014-07-06", "naknek-kvichak", 13.5, 24,    495198,  491902),
      mkOps(year, "2014-07-07", "naknek-kvichak", 13.5, 24,    483617,  480939),
      mkOps(year, "2014-07-08", "naknek-kvichak", 14.5, 24,    648087,  644762),
      mkOps(year, "2014-07-09", "naknek-kvichak", 14.5, 24,    749780,  744925),
      mkOps(year, "2014-07-10", "naknek-kvichak", 14,   24,    362620,  358399),
      mkOps(year, "2014-07-11", "naknek-kvichak", 13.5, 24,    304361,  299536),
      mkOps(year, "2014-07-12", "naknek-kvichak", 14,   24,    663499,  649416),
      mkOps(year, "2014-07-13", "naknek-kvichak", 14,   24,    281620,  273573),
      mkOps(year, "2014-07-14", "naknek-kvichak", 14.5, 24,    190840,  184084),
      mkOps(year, "2014-07-15", "naknek-kvichak", 13.5, 24,     54512,   52587, ["drift_naknek_section_only_one_of_two_periods"]),
      mkOps(year, "2014-07-16", "naknek-kvichak", 14.5, 24,     30291,   29220, ["drift_naknek_section_only_one_of_two_periods"]),

      // EGEGIK (Table 10) — 2014-06-25..2014-07-16
      mkOps(year, "2014-06-25", "egegik", 6,    8,     323564, 322625),
      mkOps(year, "2014-06-26", "egegik", 12,   8,     837029, 835758),
      mkOps(year, "2014-06-27", "egegik", 10,   8,     676648, 674733),
      mkOps(year, "2014-06-28", "egegik", 11,   23,    674461, 673454),
      mkOps(year, "2014-06-29", "egegik", 6,    8,     247454, 246987),
      mkOps(year, "2014-06-30", "egegik", 5,    16,    171926, 171580),
      mkOps(year, "2014-07-01", "egegik", 16,   1,      20475,  20326),
      mkOps(year, "2014-07-02", "egegik", 6,    16,    373277, 372695),
      mkOps(year, "2014-07-03", "egegik", 16,   2,      69312,  69104),
      mkOps(year, "2014-07-04", "egegik", 11.5, 15,    463910, 462813),
      mkOps(year, "2014-07-05", "egegik", 15.5, 15.5,  486337, 484804),
      mkOps(year, "2014-07-06", "egegik", 17.5, 15.25, 252317, 251517),
      mkOps(year, "2014-07-07", "egegik", 19.5, 15.3,  316448, 315242),
      mkOps(year, "2014-07-08", "egegik", 13.5, 15,    441257, 440069),
      mkOps(year, "2014-07-09", "egegik", 13.5, 15.5,  210427, 208725),
      mkOps(year, "2014-07-10", "egegik", 14,   14.5,  209473, 207612),
      mkOps(year, "2014-07-11", "egegik", 13.5, 15.25, 320332, 317774),
      mkOps(year, "2014-07-12", "egegik", 13,   15,    160406, 158770),
      mkOps(year, "2014-07-13", "egegik", 14,   15.5,  161404, 158456),
      mkOps(year, "2014-07-14", "egegik", 24,   24,    104384, 102989),
      mkOps(year, "2014-07-15", "egegik", 24,   24,     67659,  66820),
      mkOps(year, "2014-07-16", "egegik", 24,   24,     67664,  66565),

      // -------------------------
// NUSHAGAK (Table 19) — 2014-06-25 to 2014-07-16
// driftOpenHours = max(Nush drift, Igush drift)
// setOpenHours   = max(Nush set,   Igush set)
// -------------------------

mkOps(year, "2014-06-25", "nushagak", 4,   8.5,  606633, 546409, ["hours_max_across_sections"]),
mkOps(year, "2014-06-26", "nushagak", 15,  23.5, 537686, 510955, ["hours_max_across_sections"]),
mkOps(year, "2014-06-27", "nushagak", 24,  24,   804570, 768614, ["hours_max_across_sections"]),
mkOps(year, "2014-06-28", "nushagak", 18,  21,   686658, 652896, ["hours_max_across_sections"]),
mkOps(year, "2014-06-29", "nushagak", 15,  21.5, 417996, 399753, ["hours_max_across_sections"]),
mkOps(year, "2014-06-30", "nushagak", 15,  24,   381936, 365028, ["hours_max_across_sections"]),

mkOps(year, "2014-07-01", "nushagak", 15,  24,   237589, 226107, ["hours_max_across_sections"]),
mkOps(year, "2014-07-02", "nushagak", 16,  24,   204112, 195046, ["hours_max_across_sections"]),
mkOps(year, "2014-07-03", "nushagak", 18,  24,   350442, 332214, ["hours_max_across_sections"]),
mkOps(year, "2014-07-04", "nushagak", 18,  24,   408053, 389240, ["hours_max_across_sections"]),
mkOps(year, "2014-07-05", "nushagak", 20,  24,   357329, 340131, ["hours_max_across_sections"]),
mkOps(year, "2014-07-06", "nushagak", 19,  24,   253087, 241158, ["hours_max_across_sections"]),
mkOps(year, "2014-07-07", "nushagak", 18,  24,   182639, 173118, ["hours_max_across_sections"]),
mkOps(year, "2014-07-08", "nushagak", 24,  24,   291069, 278957, ["hours_max_across_sections"]),
mkOps(year, "2014-07-09", "nushagak", 24,  24,   153810, 146290, ["hours_max_across_sections"]),
mkOps(year, "2014-07-10", "nushagak", 24,  24,   131843, 124702, ["hours_max_across_sections"]),
mkOps(year, "2014-07-11", "nushagak", 24,  24,   116015, 109458, ["hours_max_across_sections"]),
mkOps(year, "2014-07-12", "nushagak", 24,  24,   125640, 120465, ["hours_max_across_sections"]),
mkOps(year, "2014-07-13", "nushagak", 24,  24,    91629,  87797, ["hours_max_across_sections"]),
mkOps(year, "2014-07-14", "nushagak", 24,  24,    55269,  52233, ["hours_max_across_sections"]),
mkOps(year, "2014-07-15", "nushagak", 24,  24,    29334,  26907, ["hours_max_across_sections"]),
mkOps(year, "2014-07-16", "nushagak", 24,  24,    27321,  23426, ["hours_max_across_sections"]),

// -------------------------
// UGASHIK (Table 14) — 2014-06-25 to 2014-07-17
// -------------------------
mkOps(year, "2014-06-25", "ugashik", 0, 0, 0, 0),

mkOps(year, "2014-06-26", "ugashik", 9, 42, 5636, 5630),
mkOps(year, "2014-06-27", "ugashik", 0, 0, 0, 0),

// confidential day (“a”)
mkOps(year, "2014-06-28", "ugashik", 0, 0, null, null, ["confidential"]),

mkOps(year, "2014-06-29", "ugashik", 12, 12, 66968, 66311),
mkOps(year, "2014-06-30", "ugashik", 0, 0, null, null, ["confidential"]),

mkOps(year, "2014-07-01", "ugashik", 11, 11, 93407, 93194),
mkOps(year, "2014-07-02", "ugashik", 12, 12, 73319, 73009),
mkOps(year, "2014-07-03", "ugashik", 0, 0, null, null, ["confidential"]),

mkOps(year, "2014-07-04", "ugashik", 4, 12, 61504, 61151),
mkOps(year, "2014-07-05", "ugashik", 7, 12, 101853, 101111),
mkOps(year, "2014-07-06", "ugashik", 0, 0, null, null, ["confidential"]),

// table shows “7 84 …” (set hours unusually large, but we store as reported)
mkOps(year, "2014-07-07", "ugashik", 7, 84, 91215, 90626),

mkOps(year, "2014-07-08", "ugashik", 7, 12, 86930, 86485),
mkOps(year, "2014-07-09", "ugashik", 7, 12, 150362, 149474),

mkOps(year, "2014-07-10", "ugashik", 15, 9, 274755, 272110),
mkOps(year, "2014-07-11", "ugashik", 15, 12, 163363, 161848),
mkOps(year, "2014-07-12", "ugashik", 12, 9, 70312, 68917),
mkOps(year, "2014-07-13", "ugashik", 8, 10, 92642, 89359),

mkOps(year, "2014-07-14", "ugashik", 0, 0, 0, 0),

// hours not shown on your 7/15 line -> keep catch, flag hours unknown
mkOps(year, "2014-07-15", "ugashik", 0, 0, 42823, 41203, ["hours_not_reported_in_table"]),

mkOps(year, "2014-07-16", "ugashik", 0, 0, null, null, ["confidential"]),
mkOps(year, "2014-07-17", "ugashik", 15, 15, 45715, 44296, ["permits_not_available_after_registration_table_end"]),

// -------------------------
// TOGIAK (Table 21) — 2014-06-25 to 2014-07-17
// Hours not reported -> assumed 24/24.
// Blank days in the table are confidential -> store null.
// -------------------------
mkOps(year, "2014-06-25", "togiak", 24, 24, 7264, 5001, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-06-26", "togiak", 24, 24, 3485, 2073, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-06-27", "togiak", 24, 24, 2024,  638, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-06-28", "togiak", 24, 24, 454,   253, ["togiak_hours_not_reported_assumed_24"]),

mkOps(year, "2014-06-29", "togiak", 24, 24, null, null, ["togiak_hours_not_reported_assumed_24", "confidential"]),
mkOps(year, "2014-06-30", "togiak", 24, 24, 14100, 10748, ["togiak_hours_not_reported_assumed_24"]),

mkOps(year, "2014-07-01", "togiak", 24, 24, 18149, 12074, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-02", "togiak", 24, 24, 15625,  9374, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-03", "togiak", 24, 24, 11849,  5561, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-04", "togiak", 24, 24, 12005,  7524, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-05", "togiak", 24, 24, 11307,  8452, ["togiak_hours_not_reported_assumed_24"]),

mkOps(year, "2014-07-06", "togiak", 24, 24, null, null, ["togiak_hours_not_reported_assumed_24", "confidential"]),

mkOps(year, "2014-07-07", "togiak", 24, 24, 21136, 16394, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-08", "togiak", 24, 24, 21845, 16165, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-09", "togiak", 24, 24, 16115, 11647, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-10", "togiak", 24, 24, 12529,  9300, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-11", "togiak", 24, 24, 16012, 12639, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-12", "togiak", 24, 24, 20909, 17403, ["togiak_hours_not_reported_assumed_24"]),

mkOps(year, "2014-07-13", "togiak", 24, 24, null, null, ["togiak_hours_not_reported_assumed_24", "confidential"]),

mkOps(year, "2014-07-14", "togiak", 24, 24, 16741, 13247, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-15", "togiak", 24, 24, 13859, 11379, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-16", "togiak", 24, 24, 13090, 10069, ["togiak_hours_not_reported_assumed_24"]),
mkOps(year, "2014-07-17", "togiak", 24, 24, 7173, 5904, ["togiak_hours_not_reported_assumed_24", "permits_not_available_after_registration_table_end"]),
 ],

    rivers: [// =========================
// WESTSIDE TOWERS — 2014 (Table 16)
// method: tower
// Note: rows with 0/0 are valid and included.
// =========================

// WOOD
{ year, date: "2014-06-13", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 840, cumulativeEscapement: 840 },
{ year, date: "2014-06-14", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 1968, cumulativeEscapement: 2808 },
{ year, date: "2014-06-15", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 9396, cumulativeEscapement: 12204 },
{ year, date: "2014-06-16", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 3798, cumulativeEscapement: 16002 },
{ year, date: "2014-06-17", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 1752, cumulativeEscapement: 17754 },
{ year, date: "2014-06-18", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 7800, cumulativeEscapement: 25554 },
{ year, date: "2014-06-19", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 13866, cumulativeEscapement: 39420 },
{ year, date: "2014-06-20", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 8148, cumulativeEscapement: 47568 },
{ year, date: "2014-06-21", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 7314, cumulativeEscapement: 54882 },
{ year, date: "2014-06-22", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 10500, cumulativeEscapement: 65382 },
{ year, date: "2014-06-23", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 8460, cumulativeEscapement: 73842 },
{ year, date: "2014-06-24", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 21216, cumulativeEscapement: 95058 },
{ year, date: "2014-06-25", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 207522, cumulativeEscapement: 302580 },
{ year, date: "2014-06-26", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 583308, cumulativeEscapement: 885888 },
{ year, date: "2014-06-27", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 315426, cumulativeEscapement: 1201314 },
{ year, date: "2014-06-28", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 160200, cumulativeEscapement: 1361514 },
{ year, date: "2014-06-29", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 196368, cumulativeEscapement: 1557882 },
{ year, date: "2014-06-30", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 158508, cumulativeEscapement: 1716390 },
{ year, date: "2014-07-01", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 119460, cumulativeEscapement: 1835850 },
{ year, date: "2014-07-02", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 85734, cumulativeEscapement: 1921584 },
{ year, date: "2014-07-03", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 101052, cumulativeEscapement: 2022636 },
{ year, date: "2014-07-04", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 105660, cumulativeEscapement: 2128296 },
{ year, date: "2014-07-05", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 98532, cumulativeEscapement: 2226828 },
{ year, date: "2014-07-06", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 70344, cumulativeEscapement: 2297172 },
{ year, date: "2014-07-07", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 37728, cumulativeEscapement: 2334900 },
{ year, date: "2014-07-08", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 41370, cumulativeEscapement: 2376270 },
{ year, date: "2014-07-09", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 33030, cumulativeEscapement: 2409300 },
{ year, date: "2014-07-10", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 30300, cumulativeEscapement: 2439600 },
{ year, date: "2014-07-11", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 40038, cumulativeEscapement: 2479638 },
{ year, date: "2014-07-12", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 57162, cumulativeEscapement: 2536800 },
{ year, date: "2014-07-13", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 25590, cumulativeEscapement: 2562390 },
{ year, date: "2014-07-14", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 30906, cumulativeEscapement: 2593296 },
{ year, date: "2014-07-15", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 61188, cumulativeEscapement: 2654484 },
{ year, date: "2014-07-16", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 40824, cumulativeEscapement: 2695308 },
{ year, date: "2014-07-17", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 39342, cumulativeEscapement: 2734650 },
{ year, date: "2014-07-18", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 20850, cumulativeEscapement: 2755500 },
{ year, date: "2014-07-19", riverKey: "wood", method: "tower", isOperational: true, dailyEscapement: 9114, cumulativeEscapement: 2764614 },

// IGUSHIK (0/0 for 6/18–6/20 are included)
{ year, date: "2014-06-18", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 0, cumulativeEscapement: 0 },
{ year, date: "2014-06-19", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 0, cumulativeEscapement: 0 },
{ year, date: "2014-06-20", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 0, cumulativeEscapement: 0 },
{ year, date: "2014-06-21", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 96, cumulativeEscapement: 96 },
{ year, date: "2014-06-22", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 60, cumulativeEscapement: 156 },
{ year, date: "2014-06-23", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 18, cumulativeEscapement: 174 },
{ year, date: "2014-06-24", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 60, cumulativeEscapement: 234 },
{ year, date: "2014-06-25", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 114, cumulativeEscapement: 348 },
{ year, date: "2014-06-26", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 12, cumulativeEscapement: 360 },
{ year, date: "2014-06-27", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 540, cumulativeEscapement: 900 },
{ year, date: "2014-06-28", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 16488, cumulativeEscapement: 17388 },
{ year, date: "2014-06-29", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 27774, cumulativeEscapement: 45162 },
{ year, date: "2014-06-30", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 20676, cumulativeEscapement: 65838 },
{ year, date: "2014-07-01", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 21636, cumulativeEscapement: 87474 },
{ year, date: "2014-07-02", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 16428, cumulativeEscapement: 103902 },
{ year, date: "2014-07-03", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 15936, cumulativeEscapement: 119838 },
{ year, date: "2014-07-04", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 8226, cumulativeEscapement: 128064 },
{ year, date: "2014-07-05", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 7044, cumulativeEscapement: 135108 },
{ year, date: "2014-07-06", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 10056, cumulativeEscapement: 145164 },
{ year, date: "2014-07-07", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 10362, cumulativeEscapement: 155526 },
{ year, date: "2014-07-08", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 8586, cumulativeEscapement: 164112 },
{ year, date: "2014-07-09", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 14982, cumulativeEscapement: 179094 },
{ year, date: "2014-07-10", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 10470, cumulativeEscapement: 189564 },
{ year, date: "2014-07-11", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 11094, cumulativeEscapement: 200658 },
{ year, date: "2014-07-12", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 9726, cumulativeEscapement: 210384 },
{ year, date: "2014-07-13", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 8214, cumulativeEscapement: 218598 },
{ year, date: "2014-07-14", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 11964, cumulativeEscapement: 230562 },
{ year, date: "2014-07-15", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 17628, cumulativeEscapement: 248190 },
{ year, date: "2014-07-16", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 13428, cumulativeEscapement: 261618 },
{ year, date: "2014-07-17", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 12042, cumulativeEscapement: 273660 },
{ year, date: "2014-07-18", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 9534, cumulativeEscapement: 283194 },
{ year, date: "2014-07-19", riverKey: "igushik", method: "tower", isOperational: true, dailyEscapement: 11940, cumulativeEscapement: 295134 },

// TOGIAK (starts 7/03)
{ year, date: "2014-07-03", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1542, cumulativeEscapement: 1542 },
{ year, date: "2014-07-04", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 2412, cumulativeEscapement: 3954 },
{ year, date: "2014-07-05", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 2070, cumulativeEscapement: 6024 },
{ year, date: "2014-07-06", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 2124, cumulativeEscapement: 8148 },
{ year, date: "2014-07-07", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 924, cumulativeEscapement: 9072 },
{ year, date: "2014-07-08", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 870, cumulativeEscapement: 9942 },
{ year, date: "2014-07-09", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1182, cumulativeEscapement: 11124 },
{ year, date: "2014-07-10", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 3396, cumulativeEscapement: 14520 },
{ year, date: "2014-07-11", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 3534, cumulativeEscapement: 18054 },
{ year, date: "2014-07-12", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1278, cumulativeEscapement: 19332 },
{ year, date: "2014-07-13", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1704, cumulativeEscapement: 21036 },
{ year, date: "2014-07-14", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1836, cumulativeEscapement: 22872 },
{ year, date: "2014-07-15", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 1590, cumulativeEscapement: 24462 },
{ year, date: "2014-07-16", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 7434, cumulativeEscapement: 31896 },
{ year, date: "2014-07-17", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 15984, cumulativeEscapement: 47880 },
{ year, date: "2014-07-18", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 8562, cumulativeEscapement: 56442 },
{ year, date: "2014-07-19", riverKey: "togiak", method: "tower", isOperational: true, dailyEscapement: 11586, cumulativeEscapement: 68028 },
// =========================
// NUSHAGAK SONAR — 2014 (Table 17)
// method: sonar (Sockeye daily + cumulative)
// =========================
{ year, date: "2014-06-06", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 172, cumulativeEscapement: 172 },
{ year, date: "2014-06-07", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 387, cumulativeEscapement: 558 },
{ year, date: "2014-06-08", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 505, cumulativeEscapement: 1063 },
{ year, date: "2014-06-09", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 264, cumulativeEscapement: 1327 },
{ year, date: "2014-06-10", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 1560, cumulativeEscapement: 2887 },
{ year, date: "2014-06-11", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 455, cumulativeEscapement: 3342 },
{ year, date: "2014-06-12", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 1290, cumulativeEscapement: 4633 },
{ year, date: "2014-06-13", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 2178, cumulativeEscapement: 6810 },
{ year, date: "2014-06-14", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 3203, cumulativeEscapement: 10013 },
{ year, date: "2014-06-15", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 4443, cumulativeEscapement: 14456 },
{ year, date: "2014-06-16", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 3524, cumulativeEscapement: 17980 },
{ year, date: "2014-06-17", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 1250, cumulativeEscapement: 19231 },
{ year, date: "2014-06-18", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 4001, cumulativeEscapement: 23232 },
{ year, date: "2014-06-19", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 6937, cumulativeEscapement: 30169 },
{ year, date: "2014-06-20", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 2693, cumulativeEscapement: 32862 },
{ year, date: "2014-06-21", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 7469, cumulativeEscapement: 40331 },
{ year, date: "2014-06-22", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 5701, cumulativeEscapement: 46032 },
{ year, date: "2014-06-23", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 5043, cumulativeEscapement: 51075 },
{ year, date: "2014-06-24", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 23291, cumulativeEscapement: 74366 },
{ year, date: "2014-06-25", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 37572, cumulativeEscapement: 111938 },
{ year, date: "2014-06-26", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 98422, cumulativeEscapement: 210360 },
{ year, date: "2014-06-27", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 71148, cumulativeEscapement: 281507 },
{ year, date: "2014-06-28", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 31456, cumulativeEscapement: 312964 },
{ year, date: "2014-06-29", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 30528, cumulativeEscapement: 343492 },
{ year, date: "2014-06-30", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 28793, cumulativeEscapement: 372285 },
{ year, date: "2014-07-01", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 22608, cumulativeEscapement: 394894 },
{ year, date: "2014-07-02", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 21532, cumulativeEscapement: 416426 },
{ year, date: "2014-07-03", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 15697, cumulativeEscapement: 432123 },
{ year, date: "2014-07-04", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 20177, cumulativeEscapement: 452300 },
{ year, date: "2014-07-05", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 27764, cumulativeEscapement: 480063 },
{ year, date: "2014-07-06", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 19007, cumulativeEscapement: 499070 },
{ year, date: "2014-07-07", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 12901, cumulativeEscapement: 511971 },
{ year, date: "2014-07-08", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 14347, cumulativeEscapement: 526318 },
{ year, date: "2014-07-09", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 8360, cumulativeEscapement: 534679 },
{ year, date: "2014-07-10", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 10802, cumulativeEscapement: 545480 },
{ year, date: "2014-07-11", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 6779, cumulativeEscapement: 552260 },
{ year, date: "2014-07-12", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 12855, cumulativeEscapement: 565114 },
{ year, date: "2014-07-13", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 16052, cumulativeEscapement: 581167 },
{ year, date: "2014-07-14", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 6014, cumulativeEscapement: 587180 },
{ year, date: "2014-07-15", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 5235, cumulativeEscapement: 592415 },
{ year, date: "2014-07-16", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 1195, cumulativeEscapement: 593610 },
{ year, date: "2014-07-17", riverKey: "nushagak", method: "sonar", isOperational: true, dailyEscapement: 1878, cumulativeEscapement: 595488 },

// =========================
// EASTSIDE TOWERS — 2014 (Table 8)
// Source: FMR 15-24 Table 8
// Note: The pasted 6/13 “744/744” row is omitted because it conflicts with the Kvichak cumulative sequence shown later.
// =========================

// ---- KVICHAK ----
{ year, date: "2014-06-16", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 48, cumulativeEscapement: 48 },
{ year, date: "2014-06-17", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 246, cumulativeEscapement: 294 },
{ year, date: "2014-06-18", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 150, cumulativeEscapement: 444 },
{ year, date: "2014-06-19", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 132, cumulativeEscapement: 576 },
{ year, date: "2014-06-20", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 504, cumulativeEscapement: 1080 },
{ year, date: "2014-06-21", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 918, cumulativeEscapement: 1998 },
{ year, date: "2014-06-22", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 342, cumulativeEscapement: 2340 },
{ year, date: "2014-06-23", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 672, cumulativeEscapement: 3012 },
{ year, date: "2014-06-24", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 5508, cumulativeEscapement: 8520 },
{ year, date: "2014-06-25", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 70014, cumulativeEscapement: 78534 },
{ year, date: "2014-06-26", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 181032, cumulativeEscapement: 259566 },
{ year, date: "2014-06-27", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 208548, cumulativeEscapement: 468114 },
{ year, date: "2014-06-28", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 146484, cumulativeEscapement: 614598 },
{ year, date: "2014-06-29", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 236292, cumulativeEscapement: 850890 },
{ year, date: "2014-06-30", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 487236, cumulativeEscapement: 1338126 },
{ year, date: "2014-07-01", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 560844, cumulativeEscapement: 1898970 },
{ year, date: "2014-07-02", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 643110, cumulativeEscapement: 2542080 },
{ year, date: "2014-07-03", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 481890, cumulativeEscapement: 3023970 },
{ year, date: "2014-07-04", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 269208, cumulativeEscapement: 3293178 },
{ year, date: "2014-07-05", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 150894, cumulativeEscapement: 3444072 },
{ year, date: "2014-07-06", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 183108, cumulativeEscapement: 3627180 },
{ year, date: "2014-07-07", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 175422, cumulativeEscapement: 3802602 },
{ year, date: "2014-07-08", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 107208, cumulativeEscapement: 3909810 },
{ year, date: "2014-07-09", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 46506, cumulativeEscapement: 3956316 },
{ year, date: "2014-07-10", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 90108, cumulativeEscapement: 4046424 },
{ year, date: "2014-07-11", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 75072, cumulativeEscapement: 4121496 },
{ year, date: "2014-07-12", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 78036, cumulativeEscapement: 4199532 },
{ year, date: "2014-07-13", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 16848, cumulativeEscapement: 4216380 },
{ year, date: "2014-07-14", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 67704, cumulativeEscapement: 4284084 },
{ year, date: "2014-07-15", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 105000, cumulativeEscapement: 4389084 },
{ year, date: "2014-07-16", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 45726, cumulativeEscapement: 4434810 },
{ year, date: "2014-07-17", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 17736, cumulativeEscapement: 4452546 },
{ year, date: "2014-07-18", riverKey: "kvichak", method: "tower", isOperational: true, dailyEscapement: 5994, cumulativeEscapement: 4458540 },

// ---- NAKNEK ----
{ year, date: "2014-06-16", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 366, cumulativeEscapement: 1530 },
{ year, date: "2014-06-17", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 138, cumulativeEscapement: 1668 },
{ year, date: "2014-06-18", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 960, cumulativeEscapement: 2628 },
{ year, date: "2014-06-19", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 4818, cumulativeEscapement: 7446 },
{ year, date: "2014-06-20", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 2712, cumulativeEscapement: 10158 },
{ year, date: "2014-06-21", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 2160, cumulativeEscapement: 12318 },
{ year, date: "2014-06-22", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 26310, cumulativeEscapement: 38628 },
{ year, date: "2014-06-23", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 101538, cumulativeEscapement: 140166 },
{ year, date: "2014-06-24", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 132360, cumulativeEscapement: 272526 },
{ year, date: "2014-06-25", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 31542, cumulativeEscapement: 304068 },
{ year, date: "2014-06-26", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 48798, cumulativeEscapement: 352866 },
{ year, date: "2014-06-27", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 68844, cumulativeEscapement: 421710 },
{ year, date: "2014-06-28", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 146340, cumulativeEscapement: 568050 },
{ year, date: "2014-06-29", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 220260, cumulativeEscapement: 788310 },
{ year, date: "2014-06-30", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 140940, cumulativeEscapement: 929250 },
{ year, date: "2014-07-01", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 73764, cumulativeEscapement: 1003014 },
{ year, date: "2014-07-02", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 16092, cumulativeEscapement: 1019106 },
{ year, date: "2014-07-03", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 25560, cumulativeEscapement: 1044666 },
{ year, date: "2014-07-04", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 33798, cumulativeEscapement: 1078464 },
{ year, date: "2014-07-05", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 51420, cumulativeEscapement: 1129884 },
{ year, date: "2014-07-06", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 75366, cumulativeEscapement: 1205250 },
{ year, date: "2014-07-07", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 23406, cumulativeEscapement: 1228656 },
{ year, date: "2014-07-08", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 29718, cumulativeEscapement: 1258374 },
{ year, date: "2014-07-09", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 30756, cumulativeEscapement: 1289130 },
{ year, date: "2014-07-10", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 43440, cumulativeEscapement: 1332570 },
{ year, date: "2014-07-11", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 24996, cumulativeEscapement: 1357566 },
{ year, date: "2014-07-12", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 31752, cumulativeEscapement: 1389318 },
{ year, date: "2014-07-13", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 36312, cumulativeEscapement: 1425630 },
{ year, date: "2014-07-14", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 22734, cumulativeEscapement: 1448364 },
{ year, date: "2014-07-15", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 12354, cumulativeEscapement: 1460718 },
{ year, date: "2014-07-16", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 7356, cumulativeEscapement: 1468074 },
{ year, date: "2014-07-17", riverKey: "naknek", method: "tower", isOperational: true, dailyEscapement: 6354, cumulativeEscapement: 1474428 },

// ---- EGEGIK ----
{ year, date: "2014-06-14", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 3816, cumulativeEscapement: 4560 },
{ year, date: "2014-06-15", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 1578, cumulativeEscapement: 6138 },
{ year, date: "2014-06-16", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 450, cumulativeEscapement: 6588 },
{ year, date: "2014-06-17", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 1728, cumulativeEscapement: 8316 },
{ year, date: "2014-06-18", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 3672, cumulativeEscapement: 11988 },
{ year, date: "2014-06-19", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 6546, cumulativeEscapement: 18534 },
{ year, date: "2014-06-20", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 19020, cumulativeEscapement: 37554 },
{ year, date: "2014-06-21", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 12390, cumulativeEscapement: 49944 },
{ year, date: "2014-06-22", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 23232, cumulativeEscapement: 73176 },
{ year, date: "2014-06-23", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 76752, cumulativeEscapement: 149928 },
{ year, date: "2014-06-24", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 64134, cumulativeEscapement: 214062 },
{ year, date: "2014-06-25", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 25020, cumulativeEscapement: 239082 },
{ year, date: "2014-06-26", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 55992, cumulativeEscapement: 295074 },
{ year, date: "2014-06-27", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 255594, cumulativeEscapement: 550668 },
{ year, date: "2014-06-28", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 59868, cumulativeEscapement: 610536 },
{ year, date: "2014-06-29", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 82866, cumulativeEscapement: 693402 },
{ year, date: "2014-06-30", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 103500, cumulativeEscapement: 796902 },
{ year, date: "2014-07-01", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 44718, cumulativeEscapement: 841620 },
{ year, date: "2014-07-02", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 29904, cumulativeEscapement: 871524 },
{ year, date: "2014-07-03", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 54282, cumulativeEscapement: 925806 },
{ year, date: "2014-07-04", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 140862, cumulativeEscapement: 1066668 },
{ year, date: "2014-07-05", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 116454, cumulativeEscapement: 1183122 },
{ year, date: "2014-07-06", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 56892, cumulativeEscapement: 1240014 },
{ year, date: "2014-07-07", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 15090, cumulativeEscapement: 1255104 },
{ year, date: "2014-07-08", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 17994, cumulativeEscapement: 1273098 },
{ year, date: "2014-07-09", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 14358, cumulativeEscapement: 1287456 },
{ year, date: "2014-07-10", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 27966, cumulativeEscapement: 1315422 },
{ year, date: "2014-07-11", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 24522, cumulativeEscapement: 1339944 },
{ year, date: "2014-07-12", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 6336, cumulativeEscapement: 1346280 },
{ year, date: "2014-07-13", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 13842, cumulativeEscapement: 1360122 },
{ year, date: "2014-07-14", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 13146, cumulativeEscapement: 1373268 },
{ year, date: "2014-07-15", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 3312, cumulativeEscapement: 1376580 },
{ year, date: "2014-07-16", riverKey: "egegik", method: "tower", isOperational: true, dailyEscapement: 5886, cumulativeEscapement: 1382466 },

// ---- UGASHIK ----
{ year, date: "2014-06-27", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 186, cumulativeEscapement: 186 },
{ year, date: "2014-06-28", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 2514, cumulativeEscapement: 2700 },
{ year, date: "2014-06-29", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 2694, cumulativeEscapement: 5394 },
{ year, date: "2014-06-30", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 17622, cumulativeEscapement: 23016 },
{ year, date: "2014-07-01", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 43572, cumulativeEscapement: 66588 },
{ year, date: "2014-07-02", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 58434, cumulativeEscapement: 125022 },
{ year, date: "2014-07-03", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 38364, cumulativeEscapement: 163386 },
{ year, date: "2014-07-04", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 36954, cumulativeEscapement: 200340 },
{ year, date: "2014-07-05", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 43986, cumulativeEscapement: 244326 },
{ year, date: "2014-07-06", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 41334, cumulativeEscapement: 285660 },
{ year, date: "2014-07-07", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 34536, cumulativeEscapement: 320196 },
{ year, date: "2014-07-08", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 41922, cumulativeEscapement: 362118 },
{ year, date: "2014-07-09", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 26244, cumulativeEscapement: 388362 },
{ year, date: "2014-07-10", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 23682, cumulativeEscapement: 412044 },
{ year, date: "2014-07-11", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 27090, cumulativeEscapement: 439134 },
{ year, date: "2014-07-12", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 21192, cumulativeEscapement: 460326 },
{ year, date: "2014-07-13", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 16458, cumulativeEscapement: 476784 },
{ year, date: "2014-07-14", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 9492, cumulativeEscapement: 486276 },
{ year, date: "2014-07-15", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 14268, cumulativeEscapement: 500544 },
{ year, date: "2014-07-16", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 16200, cumulativeEscapement: 516744 },
{ year, date: "2014-07-17", riverKey: "ugashik", method: "tower", isOperational: true, dailyEscapement: 16056, cumulativeEscapement: 532800 },

],
  };
}

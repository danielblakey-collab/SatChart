import { YearBatch } from "../batchValidation";

export async function loadSample(): Promise<YearBatch> {
  return {
    meta: {
      year: 2024,
      togiakOutsiderOpenDate: "2024-07-27",
      togiakOutsiderOpenReason: "escapement_waiver",
    },

    forecasts: [
      {
        year: 2024,
        districtKey: "ugashik",
        units: "millions_of_fish",
        forecast: {
          inshoreRun: 4.6,
          harvest: 3.6,
          escapementGoal: { min: 0.5, max: 1.4 },
        },
        observed: {
          inshoreRun: 7.8,
          harvest: 6.0,
          escapement: 1.8,
        },
      },
    ],

    ops: [
      {
        year: 2024,
        date: "2024-06-25",
        districtKey: "ugashik",
        driftOpenHours: 6,
        setOpenHours: 0,
        driftPermits: 123,
        dualPermits: 40,
        driftBoats: 83,
        catch: { total: 95020 },
      },
    ],

    rivers: [
      {
        year: 2024,
        date: "2024-06-25",
        riverKey: "ugashik",
        method: "tower",
        isOperational: true,
        dailyEscapement: 7188,
        cumulativeEscapement: 10650,
      },
    ],
  };
}

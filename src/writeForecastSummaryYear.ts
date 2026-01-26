import { initFirestore } from "./firestore";
import { loadYear } from "./loaders";
import { validateYearBatch, assertNoErrors } from "./batchValidation";

type DistrictSummary = {
  districtKey: string;
  forecast: {
    inshoreRun: number;
    harvest: number;
    escapementGoalMin: number | null;
    escapementGoalMax: number | null;
  };
  observed: {
    inshoreRun: number;
    harvest: number;
    escapement: number;
  };
  deltas: {
    run: number;
    harvest: number;
    escapement: number;
  };
  flags: string[];
};

async function main() {
  const year = Number(process.argv[2]);
  if (!year) throw new Error("Usage: npx ts-node src/writeForecastSummaryYear.ts <year>");

  const db = initFirestore();
  const batch = await loadYear(year);

  const issues = validateYearBatch(batch);
  assertNoErrors(issues);

  const updatedAt = new Date().toISOString();

  const districts: DistrictSummary[] = batch.forecasts.map((f) => {
    const min = f.forecast.escapementGoal?.min ?? null;
    const max = f.forecast.escapementGoal?.max ?? null;
    const goalMid = min !== null && max !== null ? (min + max) / 2 : min ?? max ?? null;

    const flags: string[] = [];
    if (f.observed.inshoreRun > f.forecast.inshoreRun) flags.push("run_above_forecast");
    if (f.observed.harvest > f.forecast.harvest) flags.push("harvest_above_forecast");
    if (min !== null && f.observed.escapement < min) flags.push("below_escapement_goal");
    if (max !== null && f.observed.escapement > max) flags.push("above_escapement_goal");
    if (min !== null && max !== null && f.observed.escapement >= min && f.observed.escapement <= max)
      flags.push("escapement_goal_met");

    return {
      districtKey: f.districtKey,
      forecast: {
        inshoreRun: f.forecast.inshoreRun,
        harvest: f.forecast.harvest,
        escapementGoalMin: min,
        escapementGoalMax: max,
      },
      observed: {
        inshoreRun: f.observed.inshoreRun,
        harvest: f.observed.harvest,
        escapement: f.observed.escapement,
      },
      deltas: {
        run: f.observed.inshoreRun - f.forecast.inshoreRun,
        harvest: f.observed.harvest - f.forecast.harvest,
        escapement: goalMid !== null ? f.observed.escapement - goalMid : 0,
      },
      flags,
    };
  });

  const totals = districts.reduce(
    (acc, d) => {
      acc.forecastRun += d.forecast.inshoreRun;
      acc.observedRun += d.observed.inshoreRun;
      acc.forecastHarvest += d.forecast.harvest;
      acc.observedHarvest += d.observed.harvest;
      acc.observedEscapement += d.observed.escapement;
      return acc;
    },
    { forecastRun: 0, observedRun: 0, forecastHarvest: 0, observedHarvest: 0, observedEscapement: 0 }
  );

  const summaryDoc = {
    year,
    units: "millions_of_fish",
    districts,
    totals,
    riverSystemSeasonTotals:
      year === 2014
        ? [
            {
              riverKey: "alagnak",
              method: "aerial",
              escapement: 0.2005, // 200,500 fish -> 0.2005 million
              notes: ["season_total_only", "source_table_20_fmr15_24"],
            },
          ]
        : year === 2012
        ? [
            {
              riverKey: "alagnak",
              method: "aerial",
              escapement: 0.861747, // 861,747 fish -> 0.861747 million
              notes: ["season_total_only", "no_daily_time_series_available", "source_table_11_fmr13_20"],
            },
          ]
        : undefined,

    notes: [
      "forecast_vs_observed_from_management_report_table",
      "units_converted_to_millions_if_needed",
    ],
    updatedAt,
  };


  const ref = db
    .collection("historical")
    .doc(String(year))
    .collection("yearForecastOutcomeSummary")
    .doc("summary");

  await ref.set(summaryDoc, { merge: true });
  console.log(`🎉 Wrote forecast outcome summary for year ${year}`);
}

main().catch((e) => {
  console.error("SUMMARY WRITE FAILED:", e);
  process.exit(1);
});

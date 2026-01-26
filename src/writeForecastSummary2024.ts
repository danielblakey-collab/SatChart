import { initFirestore } from "./firestore";
import { load2024 } from "./loaders/2024";
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
    run: number;       // observed - forecast
    harvest: number;   // observed - forecast
    escapement: number;// observed - goal midpoint (if range)
  };

  flags: string[];
};

async function main() {
  const db = initFirestore();
  const batch = await load2024();

  const issues = validateYearBatch(batch);
  assertNoErrors(issues);

  const year = batch.meta.year;
  const updatedAt = new Date().toISOString();

  const districts: DistrictSummary[] = batch.forecasts.map((f) => {
    const min = f.forecast.escapementGoal?.min ?? null;
    const max = f.forecast.escapementGoal?.max ?? null;
    const goalMid =
      min !== null && max !== null ? (min + max) / 2 : min ?? max ?? null;

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
        escapement:
          goalMid !== null ? f.observed.escapement - goalMid : 0,
      },
      flags,
    };
  });

  // Simple rollups (millions)
  const totals = districts.reduce(
    (acc, d) => {
      acc.forecastRun += d.forecast.inshoreRun;
      acc.observedRun += d.observed.inshoreRun;
      acc.forecastHarvest += d.forecast.harvest;
      acc.observedHarvest += d.observed.harvest;
      acc.observedEscapement += d.observed.escapement;
      return acc;
    },
    {
      forecastRun: 0,
      observedRun: 0,
      forecastHarvest: 0,
      observedHarvest: 0,
      observedEscapement: 0,
    }
  );

  const summaryDoc = {
    year,
    units: "millions_of_fish",
    districts,
    totals,
    notes: [
      "forecast_vs_observed_from_table2",
      "district_rollups_where_applicable",
      "escapement_goals_evaluated_against_reported_ranges",
    ],
    updatedAt,
  };

  const ref = db
    .collection("historical")
    .doc(String(year))
    .collection("yearForecastOutcomeSummary")
    .doc("summary");

  await ref.set(summaryDoc, { merge: true });

  console.log("🎉 Wrote forecast outcome summary for year", year);
}

main().catch((e) => {
  console.error("SUMMARY WRITE FAILED:", e);
  process.exit(1);
});

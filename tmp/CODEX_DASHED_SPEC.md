# Deep Research dashed-line spec (must follow exactly)

Goal: Fix dashed rendering after 07/16 for specific metrics, and fix Togiak 2020 cumulative harvest after 07/17.

## Dates
- Anchor date: 07/16 (solid ends here)
- Dashed starts: 07/17

## District window
- Togiak always uses 06/17–08/20
- Other districts use the global season window

## Metrics that MUST be dashed starting 07/17
LINE metrics:
- districtRegistration
- cumulativeBoatHours
- sockeyePerDriftBoatToDate (Sockeye/Boat TD)  <-- MUST be a line graph

Also:
- Togiak 2020 cumulativeHarvest must be dashed after 07/17.

BAR metrics:
- sockeyePerDriftBoat and sockeyePerBoatHour should render as dashed bars after 07/16.
  (Implementation note: use RuleMark for dashed “bars” after 07/16.)

## Togiak 2020 confidential handling
- Confidential sockeye total = 285,800 for 07/18–08/28.
- For UI: distribute evenly across 07/18–08/20 so cumulative stays linear.
- Visually: show a dashed line segment from 07/17 to 08/20 (approximation).
- Add footnote: "Information confidential because fewer than three permit holders or processors involved in fishery. Confidential period ends 8/28. Dashed line is an approximation."

## Constraints
- Do not change district keys.
- Do not change SQLite schema.
- Prefer precomputing points outside Chart { } to avoid Swift compiler blowups.
- No giant refactors. Only touch DeepResearchView.swift (+ helper structs inside it if needed).

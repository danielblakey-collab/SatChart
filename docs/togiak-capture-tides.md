# Togiak image capture tide reference

Researched September 15, 2026. The user supplied the base Togiak image capture as **2025-09-27 22:05 UTC**, which is **September 27, 2025 at 2:05 PM AKDT** using `America/Anchorage` (UTC−08:00).

## Reference station and limitation

NOAA station **9465406 — Togiak** has no published tide predictions, harmonic constituents, or prediction offsets in its [station metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9465406.json?expand=details,products,harcon,tidepredoffsets). A prediction query returned no data. The former Summit Island, Togiak Bay station (9465283) was [removed from NOAA predictions in 2019](https://tidesandcurrents.noaa.gov/tide_pred_stn_history.html).

The caption therefore uses **9465182 — Black Rock, Walrus Islands** as a nearby regional reference, not a prediction at Togiak itself. The user confirmed Black Rock as the reference on September 15, 2026. The visible caption says “Regional reference · Togiak’s local tide may differ” and links to the named Black Rock station. It applies only to the base `togiak` pack; no capture metadata is inferred for later versions.

Black Rock is a subordinate station of Port Moller (9463502). [NOAA offsets](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9465182/tidepredoffsets.json) specify +293 minutes for high and low tides and height ratios of 0.80 and 0.82, respectively. NOAA's returned Black Rock high/low predictions already include these corrections. Do not apply the offsets again. As with Egegik, NOAA does not supply exact-minute harmonic predictions for this subordinate station.

## Source and calculation

[NOAA high/low response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&begin_date=20250926&end_date=20250928&datum=MLLW&station=9465182&time_zone=gmt&units=english&interval=hilo&format=json), retrieved September 15, 2026:

| Event | UTC on 2025-09-27 | AKDT on 2025-09-27 | Feet MLLW |
| --- | --- | --- | --- |
| Previous high | 15:09 | 7:09 AM | 6.067 |
| Image capture | 22:05 | 2:05 PM | 0.853294517, interpolated |
| Following low | 22:07 | 2:07 PM | 0.853 |

Use the existing Egegik half-cosine interpolation with `f = 416 / 418`:

`height = 6.067 + (0.853 − 6.067) × (0.5 − 0.5 × cos(π × f))`

This gives **0.853294517 ft MLLW**, displayed as **0.9 ft MLLW**. The image capture is **2 minutes before low tide**, on the falling part of the interpolated water-level curve. Low tide is **2:07 PM AKDT**, displayed as **0.9 ft MLLW**. “Falling” describes the reference station's predicted water-level trend, not a measured current direction or speed. No local Togiak spatial correction is applied.

## Integration

The existing SwiftUI caption shows the capture date/time, estimated height, predicted state, time to the nearest event, event height/time, reference qualification, and NOAA station link. Metadata is bundled and works offline. `previewDateLabel` reads the capture metadata first, replacing the old Togiak September 14 label with September 27. No map imagery, packages, raw fishery data, schema, or manifest versioning changes are needed.

## iPad thumbnail framing

Egegik and Ugashik district previews (all versions), Bristol Bay Satellite Offline, and NOAA Charts Offline now pass the full normalized image rectangle to the existing aspect-fit renderer on iPad. The renderer centers the image in the existing 280-point frame with black backing, matching Naknek/Nushagak framing. Basemap aliases are matched through the existing basename candidate lists. iPhone behavior and the existing Naknek/Nushagak crop rectangles are preserved. No thumbnail assets were edited.

## Visual verification

A temporary iPad simulator app compiled and rendered the actual `PackPreviewImage`, `thumbnailCrop(for:)`, and `OfflineMapCaptureTideCaption` source components. The four requested images were inspected at 768-point portrait and 1080-point landscape widths. Each complete image remains visible, centered, and proportional. Togiak's caption was inspected at default text size and accessibility size 3 at a 360-point width; all fields wrap without truncation. These are component renders, not an end-to-end navigation test of the production app. The temporary preview app was removed and the existing QA simulator returned to its prior shutdown state.

The full SatChart Debug build for iOS Simulator and the final incremental build both passed with no compiler output. `git diff --check` passed. Existing changes in `DistrictID.swift` and `OnlineDistrictMapsTests.swift` were preserved.

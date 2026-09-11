# Egegik image capture tides

Researched 2026-09-07; expanded 2026-09-08. All capture times are Alaska daylight time (AKDT, UTC−08:00). The original v4–v7 captions are retained. The user subsequently supplied Egegik v3 as September 14, 2025 at 1:55 PM AKDT, correcting its former May 9, 2026 date label. Ugashik v3 retains its existing date.

## Reference station

Use NOAA **9464881 — Egegik River Ent, Bristol Bay**, at 58.2383° N, 157.5000° W. This is the geographic choice for the district's coastal flats and river mouth. The other Egegik station, **9464874**, is farther upriver at 58.2167° N, 157.3750° W. This is a representative location, not a measured proof of accuracy across every part of the district. Tide timing and heights can vary spatially.

Sources: [entrance station metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9464881.json?expand=tidepredoffsets), [upriver station metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9464874.json?expand=tidepredoffsets), [Alaska district boundaries, 5 AAC 06.200(c)](https://www.akleg.gov/basis/aac.asp?title=5).

The entrance station is subordinate to Port Moller (9463502). NOAA already applies the station's time and height offsets in its returned predictions; do not apply them again. Per [NOAA prediction documentation](https://tidesandcurrents.noaa.gov/noaatidepredictionshelp.html), subordinate stations supply high/low predictions only. Capture-time heights are app-derived estimates interpolated between the surrounding NOAA events, as requested by the user; they are not direct NOAA interval predictions or measured water levels.

## Results

All times below are AKDT. Heights are feet relative to MLLW (Mean Lower Low Water). The high/low columns preserve NOAA's returned precision; the app rounds both event heights and estimated capture heights to one decimal place.

| Map | Image capture (AKDT) | Caption state and timing | Previous high (AKDT / MLLW) | Following low (AKDT / MLLW) | Source |
| --- | --- | --- | --- | --- | --- |
| v3 | 9/14/25 1:55 PM | Falling; 26 min before low tide | 2025-09-14 06:52 / 16.816 ft | 2025-09-14 14:21 / -2.090 ft | [NOAA response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464881&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20250914&end_date=20250915&interval=hilo) |
| v4 | 8/7/26 1:45 PM | Falling; 1 hr 57 min before low tide | 2026-08-07 07:49 / 17.032 ft | 2026-08-07 15:42 / -1.526 ft | [NOAA response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&begin_date=20260807&end_date=20260807&datum=MLLW&station=9464881&time_zone=lst_ldt&units=english&interval=hilo&format=json) |
| v5 | 6/23/26 1:45 PM | Falling; 3 hr 1 min before low tide | 2026-06-23 09:23 / 17.692 ft | 2026-06-23 16:46 / -0.407 ft | [NOAA response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&begin_date=20260623&end_date=20260623&datum=MLLW&station=9464881&time_zone=lst_ldt&units=english&interval=hilo&format=json) |
| v6 | 5/9/26 9:45 PM | Falling; 1 hr 56 min after high tide | 2026-05-09 19:49 / 11.142 ft | 2026-05-10 02:45 / 1.162 ft | [NOAA response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&begin_date=20260509&end_date=20260510&datum=MLLW&station=9464881&time_zone=lst_ldt&units=english&interval=hilo&format=json) |
| v7 | 7/26/26 1:55 PM | Falling; 2 hr 47 min after high tide | 2026-07-26 11:08 / 13.352 ft | 2026-07-26 19:10 / -0.332 ft | [NOAA response](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&begin_date=20260726&end_date=20260726&datum=MLLW&station=9464881&time_zone=lst_ldt&units=english&interval=hilo&format=json) |

## Estimated heights at capture

The app displays **Estimated height at capture** in feet relative to MLLW. Estimates use half-cosine interpolation, matching the existing fallback tide curve in `TidesWeatherService.interpolatedHeight`. This is a smooth approximation between extrema, not a harmonic prediction for the entrance station. It uses the actual duration of each high-to-low interval rather than assuming a six-hour half-cycle.

With `f = (captureTime − highTime) / (lowTime − highTime)`, calculate:

`estimatedHeight = highHeight + (lowHeight − highHeight) × (0.5 − 0.5 × cos(π × f))`

Use NOAA's full-precision event heights before rounding the result to 0.1 ft. All input times are AKDT, including the next-day low for v6. NOAA has already applied the entrance station's offsets to the event predictions.

| Map | Minutes after high / minutes high-to-low | Unrounded estimate (ft MLLW) | Displayed estimate (ft MLLW) |
| --- | --- | --- | --- |
| v3 | 423 / 449 | -1.934010500 | **-1.9** |
| v4 | 356 / 473 | 1.137509474 | **1.1** |
| v5 | 262 / 443 | 6.078969965 | **6.1** |
| v6 | 116 / 416 | 9.346662074 | **9.3** |
| v7 | 167 / 482 | 9.683559440 | **9.7** |

The estimate represents the selected station, not a district-wide measured surface. It does not include wind, pressure, or river-flow departures, and rounding to tenths does not imply accuracy to a tenth of a foot.

## Derivation and display

Request `product=predictions`, `station=9464881`, `time_zone=lst_ldt`, `units=english`, `datum=MLLW`, `interval=hilo`, `format=json`. Include May 10 for v6 because its following low occurs after midnight. NOAA's `lst_ldt` accounts for daylight saving time; no additional hour adjustment is made.

Each capture lies after a high and before the next low, so its predicted water-level direction is **Falling**. This describes water level, not a measured current direction or speed. The caption uses the closer of those two events, with elapsed minutes calculated directly from the timestamps. The separate event heights still belong to the labeled high or low; the new estimated-height line refers to the capture instant. Predictions do not measure wind, pressure, or river-flow effects at the time of imaging.

The five Egegik captions are bundled in `OfflineMapCaptureTide.swift` and displayed immediately below their thumbnails by `OfflineMapsView`. They work without a network connection and are tied to exact Egegik pack slugs. The NOAA station link is optional source access. Existing map dates, download URLs, version selection, and rendering are preserved.

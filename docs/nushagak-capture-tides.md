# Nushagak image capture tides

Researched September 11, 2026. The user supplied UTC capture times. Captions convert those instants to Alaska daylight time (AKDT, UTC−08:00), using the same layout as Egegik and Ugashik: capture date/time, estimated height in feet MLLW, predicted water-level direction, nearest high/low event, and NOAA station link.

## Reference and method

Use NOAA **9465261 — Clarks Point, Nushagak Bay**, at 58.8483° N, 158.5520° W. [NOAA station metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9465261.json?expand=tidepredoffsets) identifies it as a harmonic/reference station. Its position within Nushagak Bay makes it a suitable representative reference for the district's bay flats; this geographic choice does not imply that the tide is identical throughout the district.

NOAA provides a one-minute harmonic prediction for each capture instant, so no interpolation or secondary-station correction was applied. Requests use `product=predictions`, `station=9465261`, `datum=MLLW`, `time_zone=gmt`, `units=english`, `format=json`, with `interval=1` around the capture and `interval=hilo` for nearby events. Request and compare times in UTC, then convert once with `America/Anchorage` for display. All four dates are within Alaska daylight saving time.

## Results

Heights are feet relative to Mean Lower Low Water. Captions round to 0.1 ft and label the heights estimated because these are astronomical predictions, not image-derived measurements or observed water levels.

| Map | Capture UTC | Capture AKDT | NOAA height / displayed ft MLLW | Predicted state | Nearest event (AKDT) | Sources |
|---|---|---|---|---|---|---|
| Nushagak v3 | 2025-09-27 22:05 | 9/27/2025 2:05 PM | 2.707 / **2.7** | Falling | Low 2:12 PM, 2.694 ft; 7 min before low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250927+22%3A00&end_date=20250927+22%3A10&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250926+22%3A05&end_date=20250928+22%3A05&interval=hilo) |
| Nushagak v4 | 2025-09-14 21:55 | 9/14/2025 1:55 PM | 0.543 / **0.5** | Falling | Low 3:27 PM, -2.094 ft; 1 hr 32 min before low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250914+21%3A50&end_date=20250914+22%3A00&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250913+21%3A55&end_date=20250915+21%3A55&interval=hilo) |
| Nushagak v5 | 2025-08-15 21:55 | 8/15/2025 1:55 PM | 1.032 / **1.0** | Falling | Low 3:01 PM, -0.300 ft; 1 hr 6 min before low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250815+21%3A50&end_date=20250815+22%3A00&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250814+21%3A55&end_date=20250816+21%3A55&interval=hilo) |
| Nushagak v6 | 2025-10-12 22:05 | 10/12/2025 2:05 PM | -2.564 / **-2.6** | Falling | Low 2:07 PM, -2.566 ft; 2 min before low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20251012+22%3A00&end_date=20251012+22%3A10&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465261&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20251011+22%3A05&end_date=20251013+22%3A05&interval=hilo) |

Adjacent one-minute samples confirm falling water levels at all four capture instants. V3 is seven minutes before low and v6 is two minutes before low; their capture heights and low-tide heights round to the same tenth. The label describes water-level direction rather than the direction or speed of tidal currents.

## App integration and published coverage

Nushagak v3–v6 are included in the offline thumbnail/download catalog and the verified online bootstrap catalog. Districts Online uses their `nushagak_vN_xyz/{z}/{x}/{y}.png` objects and the existing version selector; fresh selection v4 shows Nushagak v4, while a saved v3/v5/v6 selection uses its matching XYZ pyramid. A selection unavailable in Nushagak falls back to its first published version (currently v3). Automatic R2 discovery still supports v1–v15.

These uploads use `nushagak_new.geojson`, with bounds west −158.940110206604, south 58.466681049701975, east −158.19475650787356, north 59.283421786680577. The online bounds now include this expanded southern/eastern footprint; native online zooms remain 4–15, with retained-parent display at 16–17. The offline MBTiles packages contain native zooms 8–15 and TMS rows.

Public HEAD requests confirmed all four JPG previews and z4 XYZ tiles, plus the v3–v5 MBTiles packages. The initial check found `nushagak_v6.mbtiles` missing. The local October 12 output's MBTiles filename and metadata still said v5, while its source-package record and saved SHA-256 identify the October 12 capture. A staging copy corrects the name/description to v6 without changing any tile blobs. The copy passes the release validator: 244,441,088 bytes, 4,427 PNG tiles, indexed lookup, SQLite integrity, and SHA-256 `84f0db6c5b9ff522d519cadea7991926c122f01e53cc0d41e8ccfb0043c60aa8`. Its two sampled native-z15 tiles agree closely with the local v6 XYZ imagery (maximum channel RMS difference below 0.3/255; they are separately encoded/resampled outputs, not byte-identical files).

## Verification and remaining publication

The iPad simulator build and all **60 selected tests** passed: online catalog/expanded-footprint coverage, discovery, five-district memory, stable version handoffs, and general app regressions. A live run of the production discovery code starting from an empty cache found all **12** published district pyramids, including Nushagak v3–v6. Compiled caption records match NOAA and the UTC-to-AKDT conversions; the eight existing Egegik/Ugashik captions are unchanged. All four new captions were rendered at normal and accessibility text sizes, with layout spot checks confirming wrapping without truncation. `git diff --check` passed.

At the end of verification, Nushagak v6's preview and XYZ were live, but the offline MBTiles object still returned 404. The corrected v6 copy is ready; its upload awaits user authorization. No bucket contents were changed during this work.

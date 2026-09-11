# Ugashik image capture tides

Researched 2026-09-08. Capture dates/times were supplied by the user in Alaska daylight time (AKDT, UTC−08:00). The captions use the same presentation as Egegik: capture date/time, estimated height in feet MLLW, tide state, nearest high/low event, and the source station link.

## Reference station and method

Use NOAA **9464512 — Dago Creek Mouth, Ugashik Bay**, at 57.6148° N, 157.6007° W. Its location in Ugashik Bay makes it a local reference for the district's bay and coastal flats. It represents conditions at that station rather than a uniform measured water surface across the district.

[Station metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9464512.json?expand=tidepredoffsets) identifies it as a harmonic/reference station. Unlike Egegik River Entrance, it supports predictions at one-minute intervals. The capture heights below come directly from NOAA's prediction for each supplied minute; no interpolation or station-offset correction was added. The app labels them estimated heights because they are astronomical predictions, not observed water levels in the image.

Query parameters: `product=predictions`, `station=9464512`, `datum=MLLW`, `time_zone=lst_ldt`, `units=english`, `format=json`. Fetch `interval=1` around the capture minute and `interval=hilo` for nearby events. NOAA adjusts the dates for daylight saving time; do not apply another offset.

## Results

All times below are AKDT. Heights are feet relative to Mean Lower Low Water (MLLW). Negative values are below MLLW. Display heights round the full returned values to 0.1 ft; that rounding does not imply accuracy to a tenth of a foot.

| Map | Capture | NOAA height / displayed height (ft MLLW) | State | Nearest event | Sources |
| --- | --- | --- | --- | --- | --- |
| Ugashik v4 | 9/14/2025 1:55 PM | -1.770 / **-1.8** | Rising | Low 1:46 PM / -1.788 ft; 9 min after low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20250914+13%3A50&end_date=20250914+14%3A00&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20250914&end_date=20250915&interval=hilo) |
| Ugashik v5 | 8/7/2026 1:45 PM | -0.299 / **-0.3** | Falling | Low 3:02 PM / -0.936 ft; 1 hr 17 min before low tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20260807+13%3A40&end_date=20260807+13%3A50&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20260807&end_date=20260808&interval=hilo) |
| Ugashik v6 | 7/26/2026 1:55 PM | 5.913 / **5.9** | Falling | High 11:04 AM / 9.468 ft; 2 hr 51 min after high tide | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20260726+13%3A50&end_date=20260726+14%3A00&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9464512&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=20260726&end_date=20260727&interval=hilo) |

The adjacent one-minute samples confirm the water level is rising for v4 and falling for v5 and v6. V4 is nine minutes after the predicted low; its small rise is hidden when both capture and low heights are rounded to one decimal. This describes water-level direction, not a measured tidal current.

## App integration

The exact Ugashik v4–v6 pack slugs are enabled in the offline download catalog. JPEG and MBTiles objects were confirmed in the existing R2 bucket. Each caption carries its own station so the displayed NOAA link and accessibility label cannot inherit Egegik's station. Egegik v3 uses the corrected user-provided date and the same entrance-station interpolation as Egegik v4–v7; see [Egegik derivation](egegik-capture-tides.md). Captions are bundled and remain available offline.

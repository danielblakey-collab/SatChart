# Naknek image capture tides

Researched September 12, 2026. Capture times were supplied in UTC and converted once using `America/Anchorage`. Both dates are in Alaska daylight saving time (AKDT, UTC−08:00).

## Reference and method

Use NOAA **9465203 — Naknek, Naknek River**, at 58.7321° N, 156.9833° W. [NOAA metadata](https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9465203.json?expand=tidepredoffsets) identifies this as a harmonic/reference station. Its position near the Naknek River entrance makes it a suitable local reference for these Naknek maps. This geographic choice is an inference, and the prediction is not a uniform water-level measurement for every part of Naknek–Kvichak.

Requests use `product=predictions`, `station=9465203`, `datum=MLLW`, `time_zone=gmt`, `units=english`, and `format=json`. The capture height comes directly from NOAA's one-minute harmonic prediction at the specified minute. Nearby `interval=hilo` predictions identify the closest high/low event. No interpolation or subordinate-station correction was needed.

## Results

Heights are feet relative to Mean Lower Low Water (MLLW), rounded to 0.1 ft in the app. The existing caption layout labels them estimated because these are astronomical predictions rather than observed or image-derived water levels.

| Map | Capture UTC | Capture AKDT | NOAA height / displayed ft MLLW | State | Nearest event (AKDT) | Sources |
|---|---|---|---|---|---|---|
| Naknek v3 | 2025-09-29 21:55 | 2025-09-29 01:55 PM AKDT | 3.321 / **3.3** | Falling | 2025-09-29 04:09 PM AKDT, 2.018 ft; 134 min before low | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465203&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250929+21%3A50&end_date=20250929+22%3A00&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465203&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20250928+21%3A55&end_date=20250930+21%3A55&interval=hilo) |
| Naknek v4 | 2025-10-26 21:46 | 2025-10-26 01:46 PM AKDT | 1.828 / **1.8** | Falling | 2025-10-26 02:04 PM AKDT, 1.786 ft; 18 min before low | [Capture prediction](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465203&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20251026+21%3A41&end_date=20251026+21%3A51&interval=1), [high/low events](https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=SatChart&station=9465203&datum=MLLW&time_zone=gmt&units=english&format=json&begin_date=20251025+21%3A46&end_date=20251027+21%3A46&interval=hilo) |

Adjacent samples five minutes before and after each capture confirm falling water levels. V3 is 2 hr 14 min before low tide; v4 is 18 min before low tide. V4's capture height and low-tide height both round to 1.8 ft. “Falling” describes predicted water-level direction, not tidal-current speed or direction. The v3 low occurs September 30 in UTC but September 29 locally.

## App integration

The Naknek–Kvichak offline download page now includes v3 and v4 with the same capture date/time, estimated height, state, nearest event, and station link used by the existing Egegik and Ugashik cards.

The public files are named `naknek_v3.mbtiles`, `naknek_v3.jpg`, `naknek_v3_xyz/`, and the corresponding v4 names. The app retains the internal district key `naknek_kvichak` and canonical installed slugs `naknek_kvichak_v3` / `naknek_kvichak_v4`. Remote MBTiles and preview candidates accept the short Naknek basename. Package and optional download-manifest identity checks normalize that alias; versioned Naknek identities must agree exactly.

Districts Online includes both published short XYZ prefixes in its initial catalog. The existing fresh-install online selection is v4, which displays Naknek v4; saved selections are preserved. Selecting v3 displays Naknek v3, while an unavailable district version falls back to v3. Discovery accepts both `naknek_kvichak` and `naknek` XYZ names through v15, persists the selected prefix, and deduplicates aliases by the canonical pack identity.

Both outputs use the existing Naknek–Kvichak AOI. The current padded online bounds cover their raster-rounded extents. Native online zooms stay 4–15, with parent imagery retained at display zooms 16–17. The shared 32 MiB decoded-frame reservation budget and two-worker discovery limit are unchanged.

## Publication verification

Public HEAD checks succeeded for both MBTiles packages, both JPG previews, and both z4 XYZ publication tiles. Both previews, the first 65,536 bytes of each remote MBTiles, and one XYZ tile per native online zoom per version (24 tiles) match the local outputs byte-for-byte. Both MBTiles range requests returned HTTP 206 with a valid SQLite header. This samples remote content; it is not a full checksum verification of every uploaded object.

The complete local packages passed `scripts/validate_mbtiles_package.py`: SQLite integrity, indexed coordinate lookup, PNG decoding, and 4,000 tiles each at zooms 8–15, using TMS rows and 256 × 256 pixels.

| File | Bytes | Local SHA-256 |
|---|---:|---|
| `naknek_v3.mbtiles` | 199,168,000 | `352ec61812a53477d8f0103b5fe9a8df533a5f8da21d7ca4a3d771ab532d363a` |
| `naknek_v4.mbtiles` | 225,382,400 | `08600400f2e328a4015d080568062d0050e45765fa374eeabeb755974b78c287` |

A live run of the app's discovery code from an empty isolated cache found all 14 published district pyramids in about 7.7 seconds, including `naknek_v3_xyz` and `naknek_v4_xyz`. The compiled caption records match NOAA results and the UTC-to-AKDT conversions; all twelve earlier Egegik, Ugashik, and Nushagak captions are unchanged.

## Build and regression verification

The iOS 26.1 iPad simulator build succeeded. All **70 selected tests** passed: 62 checks across online catalog selection, alias discovery and persistence, five-district memory reservations, stable version handoffs, and general app regressions; plus eight package-validator tests. The new package test accepts the short Naknek metadata names while retaining canonical receipt IDs, and rejects mismatched district/version identities. The five-district memory test reserved 18 MiB under the unchanged shared 32 MiB frame budget; this is not a measurement of total app RAM.

Both captions were rendered with the existing SwiftUI caption component at normal and accessibility text sizes. Spot checks of v3 at normal size and v4 at accessibility size show all tide fields wrapping without truncation. The temporary preview app was removed and the dedicated QA simulator's prior shutdown state restored. `git diff --check` passed. Physical-device testing with the live connection remains the acceptance check for map appearance and full downloads.

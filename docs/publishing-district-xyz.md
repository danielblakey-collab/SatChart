# Publishing district XYZ maps

Districts Online discovers versions 1–15 in the public `bristol-bay-sandbars-mbtiles` R2 bucket. Adding another version within this contract does not require an app update.

## Names and tile format

| District | Prefix for v1 | Prefix for v2–v15 |
|---|---|---|
| Egegik | `egegik_xyz/` or `egegik_v1_xyz/` | `egegik_vN_xyz/` |
| Ugashik | `ugashik_xyz/` or `ugashik_v1_xyz/` | `ugashik_vN_xyz/` |
| Naknek/Kvichak | `naknek_kvichak_xyz/` or `naknek_kvichak_v1_xyz/` | `naknek_kvichak_vN_xyz/` |
| Nushagak | `nushagak_xyz/` or `nushagak_v1_xyz/` | `nushagak_vN_xyz/` |
| Togiak | `togiak_xyz/` or `togiak_v1_xyz/` | `togiak_vN_xyz/` |

Replace `N` with the version number, without leading zeros. Under each prefix, publish `z/x/y.png`: 256 × 256 PNG tiles, Web Mercator XYZ coordinates (top-origin Y), native zooms 4–15, with `Content-Type: image/png`. Preserve shoreline transparency. Display zooms 16–17 reuse zoom-15 parents and do not need additional uploads.

Use the existing district AOIs. Their union bounds are bundled in `OnlineDistrictMapCatalog.bounds(for:)`; the app clips rendering and selects discovery tiles using those bounds. A pyramid with different bounds, zoom coverage, image format, or tile size needs a catalog/loader change. JPEG previews and MBTiles do not establish online availability.

## Publish and verify

1. Validate the local pyramid and upload zooms 5–15 first. Upload its zoom-4 tiles last: discovery treats those coarse objects as publication markers. Keep each version prefix immutable after publishing; use the next version number for revised imagery so existing tile caches remain valid.
2. In the app, choose **Districts Online**. Long-press **Map v#** and choose **Refresh online map versions**. The automatic check also runs when entering this mode or returning to the foreground, at most once every five minutes after a successful scan.
3. Cycle to the version and view the corresponding district. Check its shoreline, pan, zoom to 16–17, and change versions. The previous version should remain visible until the replacement view has resolved.

The scan checks up to two z4 tile headers per prefix, using two workers and a 45-second scheduling deadline. Individual requests have short timeouts. Missing prefixes are skipped; unreachable prefixes retain their last known availability. A partial upload can still have missing higher-zoom tiles, so completing the upload before publishing z4 is essential. After an interrupted scan, retry on a better connection or use manual refresh.

Only one v1 entry is shown if both aliases exist. The cached alias is preferred; on first discovery the base prefix (`district_xyz`) wins. Published version numbers are shared by the selector: for example, selecting v15 displays a district's v15 when present and its lowest published version otherwise. It does not show 75 choices or download all 75 maps.

Offline download availability remains a separate curated list in `DistrictID.offlinePackVersions`; this discovery feature does not add empty offline download cards.

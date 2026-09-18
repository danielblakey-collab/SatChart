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

Naknek/Kvichak also accepts the shorter `naknek_xyz/` or `naknek_v1_xyz/` for v1, and `naknek_vN_xyz/` for v2–v15. The app keeps `naknek_kvichak` as its internal district and installed-pack identity. Offline MBTiles and previews accept the matching `naknek` basenames too.

Replace `N` with the version number, without leading zeros. Under each prefix, publish `z/x/y.png`: 256 × 256 PNG tiles, Web Mercator XYZ coordinates (top-origin Y), native zooms 4–15, with `Content-Type: image/png`. Preserve shoreline transparency. Display zooms 16–17 reuse zoom-15 parents and do not need additional uploads.

Use the existing district AOIs. Their union bounds are bundled in `OnlineDistrictMapCatalog.bounds(for:)`; the app clips rendering and selects discovery tiles using those bounds. A pyramid with different bounds, zoom coverage, image format, or tile size needs a catalog/loader change. JPEG previews and MBTiles do not establish online availability.

## Publish and verify

1. Validate the local pyramid and upload zooms 5–15 first. Upload its zoom-4 tiles last: discovery treats those coarse objects as publication markers. Keep each version prefix immutable after publishing; use the next version number for revised imagery so existing tile caches remain valid.
2. In the app, choose **Districts Online**. Long-press **Map v#** and choose **Refresh online map versions**. The automatic check also runs when entering this mode or returning to the foreground, at most once every five minutes after a successful scan.
3. Cycle to the version and view the corresponding district. Check its shoreline, pan, zoom to 16–17, and change versions. The previous version should remain visible until the replacement view has resolved.

The scan checks up to two z4 tile headers per prefix, using two workers and a 45-second scheduling deadline. Individual requests have short timeouts. Missing prefixes are skipped; unreachable prefixes retain their last known availability. A partial upload can still have missing higher-zoom tiles, so completing the upload before publishing z4 is essential. After an interrupted scan, retry on a better connection or use manual refresh.

Only one entry per district/version is shown if multiple aliases exist. The cached alias is preferred; on first discovery the base prefix (`district_xyz`) wins. Published version numbers are shared by the selector: for example, selecting v15 displays a district's v15 when present and its lowest published version otherwise. It does not show 75 choices or download all 75 maps.

Offline download availability remains a separate curated list in `DistrictID.offlinePackVersions`; this discovery feature does not add empty offline download cards.


## Edge-cached tile delivery

Online tile URLs are centralized in `OnlineTileDelivery.baseURL`. District
availability probes and the Bristol Bay imagery underlay use the same host.
Compressed tile cache keys retain their existing prefix/z/x/y identity, so
changing the delivery host does not invalidate already cached tiles.

The production endpoint is `https://tiles.getsatchart.com`, connected to the
existing `bristol-bay-sandbars-mbtiles` R2 bucket on September 17, 2026. The
Cloudflare rule **SatChart PNG tile edge cache** applies only to this hostname
and paths ending in `.png`:

- Matching images are eligible for edge caching; successful responses respect
  origin cache headers, falling back to Cloudflare's default status-code TTL.
- HTTP status codes 400 and above use **No store**, so missing publication
  markers and transient errors are not retained at the edge.
- Browser TTL uses **Bypass cache**. The app's existing bounded tile memory and
  disk caches remain in use; its URLSession HTTP cache is already disabled.

The R2 `r2.dev` endpoint is rate limited and does not provide edge caching. Keep
that existing public URL enabled: older app releases and offline package
downloads still use it. The website's DNS and existing bucket domains are
unchanged.

When changing the delivery hostname or cache policy:

1. Wait for the custom domain and its TLS certificate to become active.
2. Compare GET responses from the current R2 URL and the new hostname for a
   district tile and a `tiles/` underlay tile. Require HTTP 200,
   `Content-Type: image/png`, and identical payload hashes.
3. Repeat the GET at the same location and verify `CF-Cache-Status: HIT`.
   HEAD is used by
   discovery, but a repeated GET is the validation for image delivery caching.
4. Ensure absent tiles still return 404 without a cache hit on repetition, since
   new versions are published under previously missing paths.
5. Update `OnlineTileDelivery.baseURL` to the verified HTTPS hostname and run the
   online district, discovery, version handoff, and cancellation regression tests.

Keep published district version prefixes immutable as described above. Do not
apply a one-year immutable cache rule to mutable catalogs or unversioned imagery.
Server-side caching does not require larger device caches, larger images, or more
concurrent downloads.

References:
- https://developers.cloudflare.com/r2/buckets/public-buckets/
- https://developers.cloudflare.com/cache/interaction-cloudflare-products/r2/

Deployment verification: district `egegik_v4_xyz/4/0/4.png` and underlay
`tiles/4/0/4.png` returned HTTP 200 with byte-for-byte matches to the original
R2 endpoint and repeated `CF-Cache-Status: HIT` responses.

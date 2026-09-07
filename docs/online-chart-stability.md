# USGS and NOAA online map stability

Implemented on `codex/refine-landscape-top-hud`, preserving the preceding district-map changes.

## Rendering and loading

USGS Topo and NOAA Charts Online use the same retained raster painter and 350 ms button-zoom readiness gate as district maps. Pinch gestures remain immediate. A complete displayed frame remains available while a replacement loads; invalidations are coalesced and deferred during camera movement. NOAA transparency uses normal alpha composition, with the lower-resolution image clipped out beneath the detail frame so chart pixels are not painted twice.

The chart policy uses a local overview around the viewport rather than loading a worldwide thumbnail pyramid. A newer viewport cancels obsolete batches and their queued requests. Changing chart services retains the ready predecessor until the new service has prepared and drawn the current view; retiring the predecessor cancels its loads and releases source-owned frames. Leaving chart mode and dismantling the map cancel outstanding work.

`OnlineChartTileStore` owns a single serial network/disk/decode lane for both services. Duplicate requests merge, the waiting queue is limited to 48 distinct keys, and each key retains at most 16 callers. Cancellation holds the network slot until URLSession reports completion. Responses are streamed with a 1 MiB body limit; non-image responses, unexpected dimensions and corrupt images do not replace working chart imagery. Transient errors use the raster retry path. HTTP 429/503 responses establish a short host cooldown.

USGS first requests `/tile/{z}/{y}/{x}?blankTile=false`; a confirmed missing cached tile falls back to the existing scale-specific export endpoint. Missing cached coordinates are remembered for an hour, avoiding repeated cache misses before export. Display zoom limits are preserved. NOAA continues to request transparent scale-specific PNG exports.

The shared chart disk cache is limited to 64 MiB and 1,024 files. NOAA entries expire six hours after fetching; USGS entries expire after seven days. Successful disk hits do not renew freshness. Source, tile coordinate, output resolution and a cache-format version separate cache identities.

## Memory limits

On the existing constrained-device profile (at most four processors or at most 4 GiB RAM), the working allocation is:

| Component | Allowance |
|---|---:|
| Shared retained/incoming chart image reservations | 16 MiB |
| Compressed USGS/NOAA cache | 2 MiB |
| Inactive Bristol/district satellite byte cache while chart mode is active | 2 MiB |
| Headroom for one streamed response and serial decode intermediates | 4 MiB |
| Total planned online payload allocation in chart mode | 24 MiB |

This partitions the existing nominal constrained online allowance rather than stacking a second full satellite cache beneath the new renderer. Moderate/modern profiles may allocate 28/40 MiB for retained chart images, corresponding to their existing 36/48 MiB online allowances. Modern nominal hardware may request 512 px exports; constrained/moderate hardware uses 256 px. Low Power Mode and thermal pressure select 256 px for new requests. Power/thermal changes and memory warnings clear expendable byte caches and cancel pending downloads. Backgrounding suspends the chart store until activation.

Every admitted image batch reserves memory before issuing loads. Its lease follows the completed frame into renderer snapshots, including a frozen gesture frame. References to the same frame share one lease. Insufficient capacity selects a coarser complete level or postpones loading; it does not evict the displayed frame. Retired and superseded frames return their reservation when the last reference disappears. There is no additional decoded-image cache below the renderer.

These are app-owned image/payload limits, not a claim that the whole process uses 24 MiB. MapKit textures, UIKit, other app features, temporary framework allocations, and a preceding non-chart map during a mode handoff are outside this accounting. Physical-device profiling is required before claiming unchanged total peak RAM or certification for a particular older model. The image-budget regression explicitly injects the constrained 16 MiB limit even when running on a modern simulator host.

## Verification

`OnlineChartStabilityTests` covers source URLs, cache/export fallback, duplicate requests, strictly serial cancellation, streamed size/error rejection, disk expiration, alpha-preserving decoding, shared frame reservations, local overviews, obsolete viewport cancellation, and mode teardown. `OnlineChartPresentationTests` exercises the real coordinator and MapKit renderer with delayed opaque USGS and translucent NOAA fixture responses.

The first visual run sampled 96 zoom frames per service with zero detected imagery or alpha changes. Retained image peaks were approximately 10.4 MiB (NOAA) and 5.6 MiB (USGS). The viewport/memory stress case peaked at approximately 13.6 MiB under the injected 16 MiB limit. Process footprint samples in visual tests include screenshot allocations and deliberately retained test windows; they are diagnostics, not a before/after production-memory comparison.

A September 7, 2026 public-service spot check near Egegik returned valid 256 px imagery from the USGS cache at zoom 13, the USGS export fallback at zoom 17, and NOAA export at zoom 13. This is a service smoke check, not a full coverage survey.

Device acceptance should repeat rapid pan/zoom, zoom-button bursts, switching between USGS/NOAA/district modes, and background/foreground transitions on weak connectivity. Check NOAA label readability after settling, recovery after failed requests, and peak process memory with Xcode Instruments. A cold or previously unvisited region can still wait for its first network response.

Final verification: 157 distinct selected checks passed across the affected test runs. The full 156-check map regression run passed before the final drawn-coverage and pressure refinements; all affected rendering/lifecycle suites were rerun afterward, including the new memory-purge check. The final focused run passed all 25 checks. Live tests sampled 96 zoom frames and 48 service-switch frames per chart service without detecting backing-surface exposure; source-owned image reservations stayed within the injected 16 MiB limit. `git diff --check` passed. These checks ran on the iOS 26.1 iPad simulator, not an older physical device.

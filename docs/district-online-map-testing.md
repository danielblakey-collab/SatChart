# District online map testing

Working copy: `/Users/danielblakey/Desktop/Scripts/SatChart-Dev`

Branch: `codex/refine-landscape-top-hud`

## Behavior

- The previous Bristol Bay online option is now **Districts Online**. Existing saved selections migrate automatically because the stored raw value remains `bristolBaySatelliteOnline`.
- **Map v#** cycles the union of discovered online version numbers, independently of downloads. Egegik v3–v7, Ugashik v4–v6, Nushagak v3–v6, and Naknek v3–v4 are currently published. Each district uses the selected number if available, otherwise its lowest published version. The online selection is saved separately from the offline selection.
- **Download Offline Maps → Egegik** includes v3–v7. Download, validation, installation, cancellation, and deletion use the existing MBTiles manager.
- Online district imagery sits above the existing baywide satellite background. All five districts support XYZ versions 1–15. Districts without a published pyramid retain the background imagery.
- Online maps share this branch’s existing bounded tile cache and request queue. Each online prefix has its own cache namespace. Changing map mode removes district online overlays; repeated updates retain the current overlay. At most one selected overlay per district is attached, regardless of how many versions are published.
- The app reads the derived MBTiles and XYZ PNG outputs. It does not read the COG master TIFF directly.

## Try it in Xcode

1. Open `Bristol Bay Sandbars/Bristol Bay Sandbars/SatChart.xcodeproj` in the SatChart-Dev working copy and run the `SatChart` scheme.
2. Choose **Districts Online** and pan to Egegik, approximately **58.246° N, 157.454° W**. No district downloads are needed.
3. Tap **Map v#** through the discovered versions (currently v3–v7), then pan to Ugashik, Nushagak, and Naknek to compare their published imagery. Long-press the button and choose **Refresh online map versions** after uploading a new pyramid. Compare imagery while panning and zooming within the district. Online district imagery uses native zooms 4–15 and reuses those parents at closer camera scales, matching Districts Offline. Satellite and both Districts modes use MapKit’s camera range for both plus-button and pinch zoom, including outside district coverage.
4. Open **Menu → Download Offline Maps** and download the desired Egegik variants. Confirm the preview, completed status, and download size.
5. Choose **Districts Offline** and cycle through the downloaded maps. Its existing selector cycles downloaded entries; when only v4–v7 are downloaded, its cycle positions 1–4 correspond to those four packages.
6. Test the downloaded district area in airplane mode. Return online, switch back to **Districts Online**, and confirm its previous online selection is restored. Switch to Satellite or NOAA and check that no district online imagery remains.

If the version button is hidden, enable **Settings → Screen Layout & Options → Map Version Selector**.

## Published objects verified on September 6, 2026

| Map | MBTiles bytes | MBTiles tiles | Offline zooms | Online zooms |
|---|---:|---:|---|---|
| Egegik v4 | 33,779,712 | 836 | 8–15 | 4–15 |
| Egegik v5 | 31,494,144 | 836 | 8–15 | 4–15 |
| Egegik v6 | 30,633,984 | 836 | 8–15 | 4–15 |
| Egegik v7 | 33,046,528 | 836 | 8–15 | 4–15 |

All four full public downloads matched the local originals by SHA-256 and passed `scripts/validate_mbtiles_package.py`, including SQLite integrity, coordinate indexes, zoom metadata, and every PNG tile. HTTP range requests returned the SQLite header. All four previews matched the local files. One XYZ tile at every zoom level for every version (48 tiles total) matched its local original byte-for-byte. This samples online access; it does not download and validate every remote XYZ object.

PNG tiles are 256 × 256. MBTiles rows are TMS; online folders use XYZ without a Y flip. All four maps use the same published bounds: west -157.65951633453372, south 58.147518599073585, east -157.24748611450195, north 58.343988015946486.

## Adding future districts or versions

Publish complete XYZ pyramids using the naming and geometry contract in [Publishing district XYZ maps](publishing-district-xyz.md). Versions 1–15 for all five existing district keys are discovered automatically; no app edit or release is required for another online version within that contract. Offline download cards are still curated in `DistrictID.offlinePackVersions`.

The app checks public z4 tile headers using two workers, with no image-body download or decoding. It scans when entering Districts Online or foregrounding that mode, throttled to five minutes after a successful scan. A long-press on **Map v#** offers a manual refresh. Cached availability persists across launches; connection/server failures retain known versions, while confirmed missing pyramids are removed. This is publication discovery, not exhaustive tile validation.

All online districts share a 32 MiB reservation budget for retained, incoming, and frozen continuity frames. Each provider limits detail to 24 tiles and overview to four small tiles, selecting a complete coarser level if needed. Offscreen retained frames are released after a settled pan. Source compression/cache memory and MapKit backing resources are separate from this budget; it is not a bound on total app RAM.

## Integration status

The initial district-map feature was added to the existing `codex/refine-landscape-top-hud` working copy. That initial integration preserved the appearance editor, offline MBTiles engine, overlay implementation, and download manager. The existing deferred map updates, renderer-opacity cleanup, and map diagnostics are retained. The initial map and zoom work was committed as `6a965dbc`; branding followed in `6cc768ee`. The online version-handoff improvement below is a subsequent change on the same branch.

## Combined-branch verification

The iOS 26.1 iPad simulator build passed. The initial integration’s **115 selected tests** passed across `OnlineDistrictMapsTests`, `MBTilesHardeningTests`, and `SatChartTests`, with no failures or skips. This includes existing appearance-cache isolation, native z15 rendering at offline z16–17, and camera/update stability coverage. All four already-downloaded public R2 packages also passed this branch’s newer package validator, with matching expected SHA-256 and byte counts. `git diff --check` passed.

## Online version handoff

Version cycling keeps one attached district overlay and one renderer. A replacement XYZ provider loads offscreen while the current version remains visible. It is adopted only after the current viewport has a complete resolved tile set; an entirely missing/unpublished pyramid cannot replace working imagery. Geographic bounds and zoom limits span the published versions, so the switch does not remove/reinsert overlays or rebuild the Bristol Bay background.

A pending request belongs to the requested district/version. A newer selection, a return to the displayed version, a mode change, or teardown cancels that request's authority to change the displayed map. Transient failures retry with a bounded delay. A camera move postpones the handoff until settling and then checks the replacement against the new viewport. Each renderer ignores invalidations from a provider it no longer displays.

`OnlineDistrictVersionHandoffTests` covers delayed and failed loads, missing pyramids, rapid selections, cancellation, viewport changes, and overlay/renderer identity. Its live MapKit case cycles through actual Egegik v4 and v5 tile bytes with delayed delivery, checking both retained imagery and shoreline transparency. The v5 fixture provenance records SHA-256 hashes of the unmodified published zoom-11 PNGs.

The version-handoff change built successfully for the iOS 26.1 iPad simulator. All 9 new handoff tests passed, including 96 sampled live MapKit frames across repeated v4 ↔ v5 switches with zero detected imagery gaps or erased shoreline pixels. The other 132 selected regression tests also passed (141 distinct checks in total). This uses actual tile bytes with controlled delivery delays and failures; physical-device verification with the live R2 network remains the final acceptance check.

For device acceptance, leave v4 visible, then cycle versions while watching the district shoreline. The old imagery should stay until the selected version is ready. Repeat with a weak connection, rapid taps, and a pan during loading; no stale response should restore an older selection and no temporary Apple-map gap should appear inside opaque district imagery.

## Camera zoom and native district detail

Satellite, Districts Online, and Districts Offline leave the camera maximum to MapKit. The former shared application maximum of 17 constrained Apple Satellite outside district coverage and was reapplied by the delayed pinch-settle callback. Camera limits are now separate from native tile detail. Other basemap modes retain their existing application limits.

The plus button bounds its request arithmetic to zoom 30 (the tile planner’s supported range); MapKit applies its native camera limit. Settled camera updates do not impose a district-derived ceiling in these three modes. Their behavior is independent of district bounds, installed packages, or online inventory.

District and Bristol Bay continuity renderers enlarge available native parents when the camera moves closer. No higher-resolution XYZ pyramid or synthetic child tiles are requested. Native source limits, package identities, tile budgets, and version handoffs stay the same.

`MapCameraZoomRegressionTests` covers the real coordinator’s button and delayed settle paths outside district coverage, crossing district bounds, native MapKit camera limits, and unaffected basemap limits. `RasterContinuityPresentationTests.testOnlineOverzoomKeepsNativePixelsBeyondDistrictDetail` exercises zoom 15 → 16 → 17 → 18 → 19 (or MapKit’s measured maximum when lower), zoom-out, and a pinch camera at that closer scale. It checks visible imagery throughout the animation, renderer identity, and source requests capped at 15.

Verification on September 15, 2026: the iOS 26.1 iPad 9 simulator build passed. All 28 selected cases passed across the final focused runs: 15 camera cases, 10 raster-continuity cases, and 3 live presentation cases. The previous camera policy failed all 12 affected-mode camera cases while the 3 unrelated-mode cases passed. The live overzoom presentation test sampled 120 frames, requiring over 99% coverage of its synthetic opaque imagery and source requests no higher than zoom 15.

Physical-device acceptance: in each of the three modes, zoom in with both the plus button and pinch outside district coverage; wait several seconds and confirm the camera stays at the chosen scale. Pan into and out of a district, then repeat while switching district versions. Verify zoom-out still works at MapKit’s closest camera scale.

## Automatic district discovery verification — September 8, 2026

The final iPad simulator build passed. All 164 selected checks passed across the discovery, five-district memory, catalog, version handoff, Egegik real-tile rendering, continuity, USGS/NOAA, MBTiles hardening, and general app regression suites. The expanded catalog and smaller per-provider tile allowance required updating two older fixtures: explicit v4 selection in the layer-order check, and a z12 viewport that fits the detail allowance in the sharpening check.

The five-district stress case retained 19 MiB of decoded frame reservations under the shared 32 MiB cap. The live MapKit version-switch check sampled 96 real Egegik v4/v5 frames without detected imagery gaps; the child-zoom check sampled another 96 frames with full opaque-area coverage and source requests capped at z15. These are simulator checks, not total-RAM measurements on an older physical device.

A separate live run of the production URLSession discovery code, starting from an empty isolated cache, found exactly eight R2 pyramids in about 14 seconds: Egegik v3–v7 and Ugashik v4–v6. The scan used public HEAD requests only. Future v1/v15 discovery, alias handling, missing versions, interrupted scans, persistent availability, and all five district keys were exercised with controlled responses. `git diff --check` passed.

## Nushagak v3–v6 — September 11, 2026

The default online catalog now includes the four published Nushagak XYZ pyramids. They use the existing global map-version selection and stable handoffs. The Nushagak bounds include the expanded `nushagak_new` footprint; its southeast flats are covered by a regression check. The offline cards use NOAA Clarks Point predictions for their capture captions; see [capture times, heights, and sources](nushagak-capture-tides.md).

## Naknek v3–v4 — September 12, 2026

The offline cards and initial online catalog include the published Naknek v3 and v4 maps. Short `naknek_vN` upload names are supported alongside the app's canonical `naknek_kvichak_vN` identity for downloads, previews, package validation, and XYZ discovery. Both XYZ prefixes work with the existing version selector and stable handoffs. See [capture times, heights, and verification](naknek-capture-tides.md).

## Retired download cards and reference thumbnail crops — September 12, 2026

The Offline Maps page now lists Nushagak v3–v6, Naknek–Kvichak v3–v4, Egegik v3–v7, Ugashik v4–v6, and the existing Togiak map. The retired district cards and the entire Shorelines download section are removed. Basemap cards remain available. Existing local map recognition and the online v1–v15 discovery contract are unchanged.

Naknek and Nushagak thumbnails now use source-image crop regions matched to the user's reference images. Naknek shows the lower bay with the upstream rivers cropped away: `(0, 639, 715, 627)` in the 1600 × 1266 previews. Nushagak shows the bay and tidal flats: `(0, 1032, 1600, 2008)` in the 1600 × 3392 previews. These replace the earlier approximate Nushagak scale and vertical offset.

The rectangles are normalized and shared across each district's versions. The cropped area fits inside the existing 280-point preview frame with a black background, preserving the requested geographic framing at phone and tablet widths. Other districts retain their existing framing. The implementation uses SwiftUI layout and clipping with the already-loaded image; it creates no additional cropped bitmap or cached image. Source JPGs, map tiles, and tide captions are unchanged.

Verification: the catalog cleanup passed all 45 selected catalog/app regression tests. After applying the reference crops, the app built successfully for the iPad simulator. All six remaining Naknek/Nushagak versions were rendered with the production thumbnail component at 330- and 750-point card widths; visual comparisons confirmed the requested boundaries across versions and both widths. The temporary preview app was removed and the QA simulator restored to its previous shutdown state. `git diff --check` passed.

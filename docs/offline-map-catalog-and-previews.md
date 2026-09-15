# Offline map catalog and preview fixes

Updated September 15, 2026 in SatChart-Dev.

## Published district versions

The download screen now uses `OfflineDistrictPackAvailability`, independently of the online XYZ catalog or the local package inventory. For all five districts it probes supported versions 1–15, with at most two concurrent HEAD requests, and shows a card only after both the MBTiles and a JPG/JPEG/PNG preview are present. Canonical district keys remain unchanged. Short Naknek, explicit v1, and supported hyphen aliases resolve consistently for discovery and download URLs.

There are no guessed first-launch cards. Verified pairs persist for offline use. Confirmed 404/410 responses remove missing pairs; transient network/server failures retain the last verified pair. Completed checks publish incrementally. Within an app session, refreshes coalesce, run at most every five minutes unless requested by pull-to-refresh, and retry failures after one minute on the next appearance. Scans have a 45-second scheduling budget with per-request timeouts; timed-out scans resume later across districts/versions so slow connections do not repeatedly skip the same candidates.

Installed maps and active downloads absent from the verified catalog retain compact management rows without a blank image. Districts with no published or retained maps have no empty section. `DistrictID.packs` remains a local inventory helper and does not control visible download cards.

The production catalog was run against public R2 from an empty isolated cache. It completed in 11.82 seconds and found these pairs:

| District | Available versions |
| --- | --- |
| Togiak | Base (v1) only |
| Nushagak | v3, v4, v5, v6 |
| Naknek–Kvichak | v3, v4 |
| Egegik | v3, v4, v5, v6, v7 |
| Ugashik | v4, v5, v6 |

Cache restoration reproduced the verified list. No Togiak v2–v15 cards were produced. This checks file availability/type/size via HEAD, not full validation of every remote MBTiles or image during discovery. Downloads still use the existing full validation before installation.

## Black basemap preview backgrounds

The two legacy basemap JPGs contain solid gray outside their map footprints. `OfflineBasemapPreview` removes only border-connected neutral matte while decoding the display preview, with conservative color matching and an inset/row reference for the NOAA export's thin top shadow. Enclosed gray chart details are retained. Previews downsample to a maximum 2048-pixel side and processing occurs off the main actor. The iPad aspect-fit framing remains in place. Both iPad and iPhone use the black-background result.

No source JPG, MBTiles tile, R2 object, or raw fisheries data was edited. An exact before/after pixel audit of both current JPGs found no colored pixel changes and no changes to the location or RGBA values of retained pixels. Bristol Bay changed 414,121 matte/fringe pixels to black; NOAA changed 2,416,981, including its top border. Native component previews were inspected at iPad portrait/landscape and iPhone widths.

## Satellite download failure

The valid Bristol Bay Satellite Offline package was rejected after transfer because its embedded name differs from its download slug. The validator now accepts that one verified legacy-name pair, with all content/integrity checks retained. Full object evidence and the exact reproduced error are in [bristol-bay-offline-download.md](bristol-bay-offline-download.md).

## Regression checks

Seven catalog tests cover empty first launch, pair requirements, aliases, bounded/coalesced requests, cache restoration, transient failures, removal, cancellation, and budget-limited scan resumption. Background fixtures cover enclosed same-gray details, nonuniform image corners, the NOAA shadow, and asymmetric colored edge content. The satellite tests cover the exact legacy name, unrelated/versioned names, corrupt tiles, and checksum failure.

The iPad (9th generation) iOS 26.1 simulator build and all **96 selected tests** passed with zero failures or skips across `OfflineDistrictPackAvailabilityTests`, `OfflineBasemapPreviewTests`, `MBTilesHardeningTests`, and `OnlineDistrictMapsTests`. The repeated run after actor-isolation cleanup produced no compiler warnings. Result bundle: `/tmp/satchart-offline-final.xcresult`.

A final UI review added failed-preview retry on refresh (without reloading successful previews) and management rows for restored background downloads, which may have no active-pack pointer after relaunch. These view-only recovery changes received a final compile check. Component rendering and full-package validation are recorded above; a physical-device download through the app remains the final user acceptance check.

The final recovery-view build passed with no compiler output; `git diff --check` passed. The temporary preview app was removed and the QA simulator restored to its initial shutdown state.

# District online map testing

Working copy: `/Users/danielblakey/Desktop/SatChart-Dev`

Branch: `codex/refine-landscape-top-hud`

## Behavior

- The previous Bristol Bay online option is now **Districts Online**. Existing saved selections migrate automatically because the stored raw value remains `bristolBaySatelliteOnline`.
- **Map v4 → v5 → v6 → v7 → v4** selects published Egegik XYZ imagery, independently of downloads. The online version is saved separately from the offline selection.
- **Download Offline Maps → Egegik** includes v4, v5, v6, and v7 alongside the existing versions. Download, validation, installation, cancellation, and deletion use the existing MBTiles manager.
- Online district imagery sits above the existing baywide satellite background. Only Egegik currently has published district XYZ folders; other areas retain the background imagery.
- Online maps share this branch’s existing bounded tile cache and request queue. Each online version has its own cache namespace. Changing map mode removes district online overlays; repeated updates retain the current overlay.
- The app reads the derived MBTiles and XYZ PNG outputs. It does not read the COG master TIFF directly.

## Try it in Xcode

1. Open `Bristol Bay Sandbars/Bristol Bay Sandbars/SatChart.xcodeproj` in the SatChart-Dev working copy and run the `SatChart` scheme.
2. Choose **Districts Online** and pan to Egegik, approximately **58.246° N, 157.454° W**. No district downloads are needed.
3. Tap **Map v#** through v4, v5, v6, and v7. Compare imagery while panning and zooming within the district. Online district imagery uses native zooms 4–15 and reuses zoom-15 parents for display zooms 16–17, matching Districts Offline. Both the plus button and pinch gestures stop at display zoom 17.
4. Open **Menu → Download Offline Maps** and download the desired Egegik variants. Confirm the preview, completed status, and download size.
5. Choose **Districts Offline** and cycle through the downloaded maps. Its existing selector cycles downloaded entries; when only v4–v7 are downloaded, its cycle positions 1–4 correspond to those four packages.
6. Test the downloaded district area in airplane mode. Return online, switch back to **Districts Online**, and confirm its previous online selection is restored. Switch to Satellite or NOAA and check that no Egegik online imagery remains.

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

Add downloadable versions in `DistrictID.offlinePackVersions`. Add verified online pyramids, their native zoom range, and their actual bounds in `OnlineDistrictMapCatalog.maps`. Do not enable online versions solely because an MBTiles file exists: the corresponding `<slug>_xyz/{z}/{x}/{y}.png` objects must also be published. District keys remain unchanged.

The catalog presents the union of published version numbers. For a district without the selected number, it uses that district's first published online version.

## Integration status

The district-map feature was added to the existing `codex/refine-landscape-top-hud` working copy. The appearance editor, offline MBTiles engine, overlay implementation, and download manager were preserved byte-for-byte. The existing deferred map updates, renderer-opacity cleanup, and map diagnostics are retained. The initial map and zoom work was committed as `6a965dbc`; branding followed in `6cc768ee`. The online version-handoff improvement below is a subsequent change on the same branch.

## Combined-branch verification

The iOS 26.1 iPad simulator build passed. The initial integration’s **115 selected tests** passed across `OnlineDistrictMapsTests`, `MBTilesHardeningTests`, and `SatChartTests`, with no failures or skips. This includes existing appearance-cache isolation, native z15 rendering at offline z16–17, and camera/update stability coverage. All four already-downloaded public R2 packages also passed this branch’s newer package validator, with matching expected SHA-256 and byte counts. `git diff --check` passed.

## Online version handoff

Version cycling keeps one attached district overlay and one renderer. A replacement XYZ provider loads offscreen while the current version remains visible. It is adopted only after the current viewport has a complete resolved tile set; an entirely missing/unpublished pyramid cannot replace working imagery. Geographic bounds and zoom limits span the published versions, so the switch does not remove/reinsert overlays or rebuild the Bristol Bay background.

A pending request belongs to the requested district/version. A newer selection, a return to the displayed version, a mode change, or teardown cancels that request's authority to change the displayed map. Transient failures retry with a bounded delay. A camera move postpones the handoff until settling and then checks the replacement against the new viewport. Each renderer ignores invalidations from a provider it no longer displays.

`OnlineDistrictVersionHandoffTests` covers delayed and failed loads, missing pyramids, rapid selections, cancellation, viewport changes, and overlay/renderer identity. Its live MapKit case cycles through actual Egegik v4 and v5 tile bytes with delayed delivery, checking both retained imagery and shoreline transparency. The v5 fixture provenance records SHA-256 hashes of the unmodified published zoom-11 PNGs.

The version-handoff change built successfully for the iOS 26.1 iPad simulator. All 9 new handoff tests passed, including 96 sampled live MapKit frames across repeated v4 ↔ v5 switches with zero detected imagery gaps or erased shoreline pixels. The other 132 selected regression tests also passed (141 distinct checks in total). This uses actual tile bytes with controlled delivery delays and failures; physical-device verification with the live R2 network remains the final acceptance check.

For device acceptance, leave v4 visible, then cycle versions while watching the district shoreline. The old imagery should stay until the selected version is ready. Repeat with a weak connection, rapid taps, and a pan during loading; no stale response should restore an older selection and no temporary Apple-map gap should appear inside opaque district imagery.

## Online child zooms 16–17

Districts Online now shares the offline camera limit of 17. Its existing continuity renderer scales retained native zoom-15 parents at zooms 16 and 17; no zoom-16/17 XYZ objects are required. The Bristol Bay online backing layer uses the same display limit. Version handoffs continue to prepare the current view using native parents and retain the same overlay and renderer.

The live MapKit child-zoom regression exercises 15 → 16 → 17, an extra plus tap at the limit, zooming out, and the pinch clamp. It checks visible imagery throughout the animation, renderer identity, and that network source requests never exceed zoom 15.

Child-zoom verification: the iPad simulator build and all 29 selected tests passed across the online catalog, version handoff, raster continuity, and presentation suites. The new live test sampled 96 zoom frames with 100% coverage of its opaque test area and a maximum requested source zoom of 15. The real v4/v5 version-switch check also retained all 96 sampled frames. Physical-device acceptance should repeat plus-button and pinch zooms to 16/17, then switch versions at that scale.

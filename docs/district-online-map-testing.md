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
3. Tap **Map v#** through v4, v5, v6, and v7. Compare imagery while panning and zooming within the district. Online district imagery uses native zooms 4–15. The existing offline display zooms 16–17 remain available.
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

The district-map feature was added to the existing `codex/refine-landscape-top-hud` working copy. The appearance editor, offline MBTiles engine, overlay implementation, and download manager were preserved byte-for-byte. The existing deferred map updates, renderer-opacity cleanup, and map diagnostics are retained. Earlier changes and this feature remain uncommitted.

## Combined-branch verification

The iOS 26.1 iPad simulator build passed. All **115 selected tests** passed across `OnlineDistrictMapsTests`, `MBTilesHardeningTests`, and `SatChartTests`, with no failures or skips. This includes existing appearance-cache isolation, native z15 rendering at offline z16–17, and camera/update stability coverage. All four already-downloaded public R2 packages also passed this branch’s newer package validator, with matching expected SHA-256 and byte counts. `git diff --check` passed.

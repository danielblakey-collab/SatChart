# Bristol Bay Satellite Offline download validation

## Diagnosis (2026-09-15)

The public `bristol_bay.mbtiles` object finishes transferring successfully, then the app rejects its embedded package name:

```text
Map identity mismatch (expected bristol_bay, found bbay_entire_bay_z4_13).
```

This was reproduced with the actual R2 payload using `MBTilesPackageValidator.swift`. The embedded name is the legacy export name, while the download catalog uses the installed slug `bristol_bay`.

Source: https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev/bristol_bay.mbtiles

Observed object:

- Last modified: 2026-03-30 16:26:38 UTC
- Byte count: 133,980,160
- SHA-256: `b83c74ef048d56691d015ae4be04090050767265ad80fb493f3f6b7deafc1958`
- ETag: `9ee3327791cdad67163094a2fc800f15`
- 6,188 PNG tiles, 256 x 256 pixels, zooms 4 through 13, TMS storage
- SQLite `quick_check` and full `integrity_check`: `ok`
- Coordinate lookup uses the unique `tile_index` index
- No duplicate or out-of-range coordinates; every tile passed the release validator
- The public `bristol_bay.manifest.json` sidecar returned HTTP 404

## Fix

The app accepts the exact pair of installed slug `bristol_bay` and embedded name `bbay_entire_bay_z4_13`. Other names and district identities keep their existing validation rules. The size, hash (when supplied), SQLite, coordinate, index, geographic bounds, and raster checks remain in force. No R2 object, SQLite schema, or stored map data is changed.

Regression coverage checks acceptance of the legacy name, rejection for other districts/versions and similar unknown names, and continued rejection of corrupt images and checksum mismatches.

## Reproduce release validation

Download the public object to a temporary path and run:

```sh
python3 scripts/validate_mbtiles_package.py /tmp/bristol_bay.mbtiles \
  --id bristol_bay --version r2-2026-03-30 \
  --expected-bytes 133980160 \
  --expected-sha256 b83c74ef048d56691d015ae4be04090050767265ad80fb493f3f6b7deafc1958
```

These pinned values describe the observed object, not a permanent release manifest. A future replacement must be inspected and validated independently.

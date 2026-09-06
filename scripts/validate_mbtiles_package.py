#!/usr/bin/env python3
"""Streaming release validator and manifest generator for SatChart MBTiles.

This utility is intentionally read-only. It never creates indexes or repairs packages;
failed packages must be rebuilt in staging before any R2 upload.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sqlite3
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

try:
    from PIL import Image as PillowImage
except ImportError:  # PNG validation below remains dependency-free.
    PillowImage = None

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_SIGNATURE = b"\xff\xd8\xff"
MAX_ZOOM = 30
DEFAULT_MAX_BLOB = 8 * 1024 * 1024


class ValidationFailure(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--id", required=True, dest="package_id")
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, help="Write JSON here instead of stdout")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--expected-bytes", type=int)
    parser.add_argument(
        "--legacy-scheme-override",
        choices=("tms", "xyz"),
        help="Explicit compatibility rule for a legacy package missing metadata.scheme",
    )
    parser.add_argument("--max-blob-bytes", type=int, default=DEFAULT_MAX_BLOB)
    parser.add_argument("--fail-on-hole-candidates", action="store_true")
    return parser.parse_args()


def fail(condition: bool, message: str) -> None:
    if condition:
        raise ValidationFailure(message)


def file_sha256(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            size += len(chunk)
            digest.update(chunk)
    return digest.hexdigest(), size


def object_exists(db: sqlite3.Connection, name: str) -> bool:
    return db.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=? LIMIT 1", (name,)
    ).fetchone() is not None


def columns(db: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]).lower() for row in db.execute(f"PRAGMA table_info({table})")}


def metadata(db: sqlite3.Connection) -> dict[str, str]:
    if not object_exists(db, "metadata"):
        return {}
    return {str(name).lower(): str(value) for name, value in db.execute("SELECT name,value FROM metadata")}


def parse_bounds(raw: str | None) -> list[float] | None:
    if not raw:
        return None
    try:
        values = [float(value.strip()) for value in raw.split(",")]
    except ValueError as exc:
        raise ValidationFailure("metadata.bounds is not numeric") from exc
    fail(len(values) != 4, "metadata.bounds must contain four values")
    west, south, east, north = values
    fail(not (-180 <= west < east <= 180 and -90 <= south < north <= 90), "metadata.bounds is implausible")
    return values


def parse_png(data: bytes) -> tuple[str, int, int]:
    fail(not data.startswith(PNG_SIGNATURE), "invalid PNG signature")
    offset = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = interlace = None
    compressed: list[bytes] = []
    saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        fail(end > len(data), "truncated PNG chunk")
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        fail(actual_crc != expected_crc, "PNG CRC mismatch")
        if chunk_type == b"IHDR":
            fail(length != 13, "invalid PNG IHDR")
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            compressed.append(payload)
        elif chunk_type == b"IEND":
            saw_end = True
            break
        offset = end
    fail(not saw_end or width is None or height is None or not compressed, "incomplete PNG")
    fail(width <= 0 or height <= 0, "invalid PNG dimensions")
    try:
        raster = zlib.decompress(b"".join(compressed))
    except zlib.error as exc:
        raise ValidationFailure("PNG raster stream cannot be decompressed") from exc
    fail(not raster, "empty PNG raster stream")
    if interlace == 0:
        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
        fail(channels is None or bit_depth not in {1, 2, 4, 8, 16}, "unsupported PNG color layout")
        row_bytes = (width * channels * bit_depth + 7) // 8
        fail(len(raster) != height * (row_bytes + 1), "PNG decoded raster length mismatch")
        fail(any(raster[row * (row_bytes + 1)] > 4 for row in range(height)), "invalid PNG filter byte")
    return "png", width, height


def parse_jpeg(data: bytes) -> tuple[str, int, int]:
    fail(not data.startswith(JPEG_SIGNATURE) or not data.endswith(b"\xff\xd9"), "truncated JPEG")
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        marker = data[offset + 1]
        offset += 2
        if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        fail(offset + 2 > len(data), "truncated JPEG marker")
        length = struct.unpack(">H", data[offset : offset + 2])[0]
        fail(length < 2 or offset + length > len(data), "invalid JPEG marker length")
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
            fail(length < 7, "invalid JPEG frame")
            height, width = struct.unpack(">HH", data[offset + 3 : offset + 7])
            fail(width <= 0 or height <= 0, "invalid JPEG dimensions")
            fail(PillowImage is None, "JPEG release validation requires Pillow (`python3 -m pip install Pillow`)")
            try:
                with PillowImage.open(io.BytesIO(data)) as image:
                    image.load()  # Force entropy decoding; header-only verification is insufficient.
                    fail(image.size != (width, height), "JPEG decoder dimensions disagree with frame header")
            except ValidationFailure:
                raise
            except Exception as exc:
                raise ValidationFailure("JPEG raster cannot be decoded") from exc
            return "jpeg", width, height
        offset += length
    raise ValidationFailure("JPEG has no supported frame header")


def parse_image(data: bytes) -> tuple[str, int, int]:
    if data.startswith(PNG_SIGNATURE):
        return parse_png(data)
    if data.startswith(JPEG_SIGNATURE):
        return parse_jpeg(data)
    raise ValidationFailure("unsupported tile image signature")


def query_plan(db: sqlite3.Connection, sql: str, normalized_schema: bool) -> str:
    rows = db.execute("EXPLAIN QUERY PLAN " + sql, (0, 0, 0)).fetchall()
    detail = " | ".join(str(row[3]) for row in rows)
    lowered = detail.lower()
    searches_coordinate_store = "search tiles" in lowered or "search map" in lowered
    fail(not searches_coordinate_store or "using" not in lowered or "index" not in lowered, f"coordinate lookup is not indexed: {detail}")
    return detail


def internal_hole_candidates(db: sqlite3.Connection) -> dict[int, int]:
    """Count horizontal gaps bracketed by tiles; informational for sparse AOIs.

    These are candidates, not automatic corruption: legitimate AOIs can be concave.
    Release operators can opt into failure after reviewing expected coverage geometry.
    """
    result: dict[int, int] = {}
    cursor = db.execute("SELECT zoom_level,tile_row,tile_column FROM tiles ORDER BY zoom_level,tile_row,tile_column")
    prior: tuple[int, int, int] | None = None
    for zoom, row, column in cursor:
        if prior and prior[0] == zoom and prior[1] == row and column > prior[2] + 1:
            result[int(zoom)] = result.get(int(zoom), 0) + int(column - prior[2] - 1)
        prior = (int(zoom), int(row), int(column))
    return result


def validate(args: argparse.Namespace) -> dict[str, object]:
    path = args.package.resolve()
    fail(not path.is_file(), f"package does not exist: {path}")
    with path.open("rb") as handle:
        fail(handle.read(16) != b"SQLite format 3\x00", "invalid SQLite header")
    sha256, byte_count = file_sha256(path)
    if args.expected_bytes is not None:
        fail(byte_count != args.expected_bytes, f"byte count mismatch: expected {args.expected_bytes}, got {byte_count}")
    if args.expected_sha256:
        fail(sha256.lower() != args.expected_sha256.lower(), "SHA-256 mismatch")

    uri = f"file:{path.as_posix()}?mode=ro&immutable=1"
    db = sqlite3.connect(uri, uri=True)
    try:
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA cache_size=-4096")
        db.execute("PRAGMA mmap_size=0")
        integrity = [row[0] for row in db.execute("PRAGMA integrity_check")]
        fail(integrity != ["ok"], "integrity_check failed: " + "; ".join(integrity))
        fail(not object_exists(db, "tiles"), "missing tiles table or view")
        tile_columns = columns(db, "tiles")
        fail(not {"zoom_level", "tile_column", "tile_row"}.issubset(tile_columns), "missing coordinate columns")
        direct = "tile_data" in tile_columns
        normalized = "tile_id" in tile_columns and object_exists(db, "images") and "tile_data" in columns(db, "images")
        fail(not direct and not normalized, "unsupported tiles/images schema")

        duplicate_count = db.execute(
            "SELECT COUNT(*) FROM (SELECT 1 FROM tiles GROUP BY zoom_level,tile_column,tile_row HAVING COUNT(*)>1)"
        ).fetchone()[0]
        fail(duplicate_count != 0, f"found {duplicate_count} duplicate tile coordinates")
        invalid_count = db.execute(
            "SELECT COUNT(*) FROM tiles WHERE zoom_level<0 OR zoom_level>? OR tile_column<0 OR tile_row<0 "
            "OR tile_column >= (1 << zoom_level) OR tile_row >= (1 << zoom_level)", (MAX_ZOOM,)
        ).fetchone()[0]
        fail(invalid_count != 0, f"found {invalid_count} invalid tile coordinates")

        data_expression = "tiles.tile_data" if direct else "images.tile_data"
        from_expression = "tiles" if direct else "tiles JOIN images ON tiles.tile_id=images.tile_id"
        lookup = (
            f"SELECT {data_expression} FROM {from_expression} WHERE tiles.zoom_level=? "
            "AND tiles.tile_column=? AND tiles.tile_row=? LIMIT 1"
        )
        plan = query_plan(db, lookup, normalized)
        meta = metadata(db)
        declared_scheme = meta.get("scheme", "").strip().lower()
        known_legacy_override = "xyz" if args.package_id.lower() == "egegik_v2" else None
        scheme = declared_scheme or args.legacy_scheme_override or known_legacy_override or "tms"
        fail(scheme not in {"tms", "xyz"}, f"unsupported scheme: {scheme}")
        bounds = parse_bounds(meta.get("bounds"))

        zoom_counts: Counter[int] = Counter()
        formats: Counter[str] = Counter()
        dimensions: Counter[tuple[int, int]] = Counter()
        tile_count = 0
        largest_blob = 0
        tile_cursor = db.execute(
            f"SELECT tiles.zoom_level,tiles.tile_column,tiles.tile_row,{data_expression} FROM {from_expression}"
        )
        for zoom, column, row, blob in tile_cursor:
            fail(blob is None or len(blob) == 0, f"zero-length tile at z={zoom}")
            fail(len(blob) > args.max_blob_bytes, f"suspicious tile blob ({len(blob)} bytes) at z={zoom}")
            image_format, width, height = parse_image(bytes(blob))
            zoom_counts[int(zoom)] += 1
            formats[image_format] += 1
            dimensions[(width, height)] += 1
            tile_count += 1
            largest_blob = max(largest_blob, len(blob))
        fail(tile_count == 0, "package contains no tiles")
        fail(len(formats) != 1, f"mixed tile formats: {dict(formats)}")
        fail(len(dimensions) != 1, f"mixed tile dimensions: {dict(dimensions)}")
        tile_format = next(iter(formats))
        tile_width, tile_height = next(iter(dimensions))
        fail(tile_width not in {256, 512} or tile_height not in {256, 512}, f"unsupported dimensions: {tile_width}x{tile_height}")
        declared_format = meta.get("format", "").lower()
        fail(bool(declared_format) and declared_format not in {tile_format, "jpg" if tile_format == "jpeg" else tile_format}, "metadata.format does not match tiles")
        min_zoom, max_zoom = min(zoom_counts), max(zoom_counts)
        if "minzoom" in meta:
            fail(int(float(meta["minzoom"])) != min_zoom, "metadata.minzoom does not match tiles")
        if "maxzoom" in meta:
            fail(int(float(meta["maxzoom"])) != max_zoom, "metadata.maxzoom does not match tiles")

        holes = internal_hole_candidates(db)
        if args.fail_on_hole_candidates:
            fail(any(holes.values()), f"internal coverage gap candidates require review: {holes}")
        return {
            "schemaVersion": 1,
            "id": args.package_id,
            "version": args.version,
            "filename": path.name,
            "byteCount": byte_count,
            "sha256": sha256,
            "bounds": bounds,
            "minimumZoom": min_zoom,
            "maximumZoom": max_zoom,
            "scheme": scheme,
            "tileFormat": tile_format,
            "tileDimensions": {"width": tile_width, "height": tile_height},
            "tileCount": tile_count,
            "tileCountsByZoom": {str(key): zoom_counts[key] for key in sorted(zoom_counts)},
            "largestTileBlobBytes": largest_blob,
            "queryPlan": plan,
            "internalCoverageGapCandidatesByZoom": {str(key): holes[key] for key in sorted(holes)},
            "authoritativeHash": True,
        }
    finally:
        db.close()


def main() -> int:
    args = parse_args()
    try:
        manifest = validate(args)
    except (OSError, sqlite3.Error, ValidationFailure, ValueError) as exc:
        print(json.dumps({"valid": False, "error": str(exc)}, indent=2), file=sys.stderr)
        return 1
    payload = json.dumps({"valid": True, "package": manifest}, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

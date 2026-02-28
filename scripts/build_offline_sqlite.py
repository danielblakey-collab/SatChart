import csv
import glob
import os
import sqlite3
import gzip
import shutil
from datetime import datetime
from typing import Optional

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DATA = os.path.join(REPO_ROOT, "src", "data")
BUILD_DIR = os.path.join(REPO_ROOT, "build", "offline")

OUT_SQLITE = os.path.join(BUILD_DIR, "offline.sqlite")
OUT_GZ = os.path.join(BUILD_DIR, "offline.sqlite.gz")

ALLOCATION_CSV_CANDIDATES = [
    os.path.join(REPO_ROOT, "src", "data", "alloc", "allocation_by_district_2004_2024.csv"),
    os.path.join(REPO_ROOT, "src", "data", "alloc", "appendix_a9_2004_2024.csv"),
]

FORECAST_VS_ACTUAL_CSV = os.path.join(
    REPO_ROOT, "src", "data", "metrics", "river_system_forecast_vs_actual.csv"
)

DISTRICT_YEAR_ADJ_CSV = os.path.join(
    REPO_ROOT, "src", "data", "metrics", "district_year_adjustments.csv"
)

OPS_GLOB = os.path.join(SRC_DATA, "[0-9][0-9][0-9][0-9]", "*_ops_*.csv")
REG_GLOB = os.path.join(SRC_DATA, "[0-9][0-9][0-9][0-9]", "registration_*.csv")
RIVER_GLOB = os.path.join(SRC_DATA, "[0-9][0-9][0-9][0-9]", "rivers_*.csv")

def to_int(x: Optional[str]) -> Optional[int]:
    if x is None:
        return None
    s = str(x).strip()
    if s == "" or s.lower() == "nd":
        return None
    try:
        return int(float(s))
    except Exception:
        return None


def to_float(x: Optional[str]) -> Optional[float]:
    if x is None:
        return None
    s = str(x).strip()
    if s == "" or s.lower() == "nd":
        return None
    try:
        return float(s)
    except Exception:
        return None


def to_bool_int(x: Optional[str]) -> Optional[int]:
    if x is None:
        return None
    s = str(x).strip().lower()
    if s == "" or s == "nd":
        return None
    if s in ("true", "t", "1", "yes", "y"):
        return 1
    if s in ("false", "f", "0", "no", "n"):
        return 0
    return None


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def connect_db(path: str) -> sqlite3.Connection:
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA temp_store=MEMORY;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS districts (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS rivers (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS river_day (
          year INTEGER NOT NULL,
          date TEXT NOT NULL,
          riverId INTEGER NOT NULL,
          method TEXT NOT NULL,

          isOperational INTEGER,
          dailyEscapement INTEGER,
          cumulativeEscapement INTEGER,

          flags TEXT,
          notes TEXT,

          PRIMARY KEY (year, date, riverId, method),
          FOREIGN KEY (riverId) REFERENCES rivers(id)
        );

        CREATE INDEX IF NOT EXISTS idx_river_year_date ON river_day(year, date);
        CREATE INDEX IF NOT EXISTS idx_river_river_date ON river_day(riverId, date);

        CREATE TABLE IF NOT EXISTS ops_day (
          year INTEGER NOT NULL,
          date TEXT NOT NULL,
          districtId INTEGER NOT NULL,

          driftOpenHours REAL,
          setOpenHours REAL,

          driftDeliveries INTEGER,
          setDeliveries INTEGER,

          sockeye INTEGER,
          chinook INTEGER,
          chum INTEGER,
          pink INTEGER,
          coho INTEGER,
          total INTEGER,

          nushagakHoursRaw TEXT,
          igushikHoursRaw TEXT,

          flags TEXT,
          notes TEXT,

          PRIMARY KEY (year, date, districtId),
          FOREIGN KEY (districtId) REFERENCES districts(id)
        );

        CREATE INDEX IF NOT EXISTS idx_ops_district_date ON ops_day(districtId, date);
        CREATE INDEX IF NOT EXISTS idx_ops_year_date ON ops_day(year, date);

        CREATE TABLE IF NOT EXISTS registration_day (
          year INTEGER NOT NULL,
          date TEXT NOT NULL,
          districtId INTEGER NOT NULL,

          driftPermits INTEGER,
          dualPermits INTEGER,
          driftBoats INTEGER,

          flags TEXT,
          notes TEXT,

          PRIMARY KEY (year, date, districtId),
          FOREIGN KEY (districtId) REFERENCES districts(id)
        );

        CREATE INDEX IF NOT EXISTS idx_reg_year_date ON registration_day(year, date);
        CREATE INDEX IF NOT EXISTS idx_reg_district_date ON registration_day(districtId, date);

        CREATE TABLE IF NOT EXISTS district_year_adjustment (
          year INTEGER NOT NULL,
          districtId INTEGER NOT NULL,
          species TEXT NOT NULL,
          officialTotal INTEGER,
          observedTotal INTEGER,
          confidentialDelta INTEGER NOT NULL,
          notes TEXT,
          PRIMARY KEY (year, districtId, species),
          FOREIGN KEY (districtId) REFERENCES districts(id)
        );

        CREATE INDEX IF NOT EXISTS idx_dya_year_district ON district_year_adjustment(year, districtId);

        CREATE TABLE IF NOT EXISTS allocation_year (
          year INTEGER NOT NULL,
          districtId INTEGER NOT NULL,
          driftPct REAL,
          setPct REAL,
          componentsJson TEXT,
          notes TEXT,
          PRIMARY KEY (year, districtId),
          FOREIGN KEY (districtId) REFERENCES districts(id)
        );

        CREATE TABLE IF NOT EXISTS river_system_fva (
          year INTEGER NOT NULL,
          riverSystemKey TEXT NOT NULL,
          inshoreRunForecast REAL,
          inshoreRunActual REAL,
          inshoreRunPctDev REAL,
          escapementGoalMin REAL,
          escapementGoalMax REAL,
          escapementGoalType TEXT,
          escapementActual REAL,
          inshoreCatchProjected REAL,
          inshoreCatchActual REAL,
          inshoreCatchPctDev REAL,
          notes TEXT,
          PRIMARY KEY (year, riverSystemKey)
        );
        """
    )
    conn.commit()


def get_or_create_district_id(conn: sqlite3.Connection, key: str) -> int:
    cur = conn.execute("SELECT id FROM districts WHERE key = ?", (key,))
    row = cur.fetchone()
    if row:
        return int(row[0])
    cur = conn.execute("INSERT INTO districts(key) VALUES(?)", (key,))
    return int(cur.lastrowid)


def get_or_create_river_id(conn: sqlite3.Connection, key: str) -> int:
    cur = conn.execute("SELECT id FROM rivers WHERE key = ?", (key,))
    row = cur.fetchone()
    if row:
        return int(row[0])
    cur = conn.execute("INSERT INTO rivers(key) VALUES(?)", (key,))
    return int(cur.lastrowid)


def infer_year_from_path(path: str) -> int:
    parts = path.replace("\\", "/").split("/")
    for p in parts:
        if p.isdigit() and len(p) == 4:
            return int(p)
    base = os.path.basename(path)
    return int(base.split("_")[-1].split(".")[0])


def load_ops(conn: sqlite3.Connection) -> None:
    files = sorted(glob.glob(OPS_GLOB))
    if not files:
        raise RuntimeError(f"No ops files found at: {OPS_GLOB}")

    insert_sql = """
      INSERT OR REPLACE INTO ops_day(
        year,date,districtId,
        driftOpenHours,setOpenHours,
        driftDeliveries,setDeliveries,
        sockeye,chinook,chum,pink,coho,total,
        nushagakHoursRaw,igushikHoursRaw,
        flags,notes
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    conn.execute("BEGIN;")
    inserted = 0

    for path in files:
        year = infer_year_from_path(path)
        district_key = os.path.basename(path).split("_ops_")[0]
        district_id = get_or_create_district_id(conn, district_key)

        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                continue

            for r in reader:
                date = (r.get("date") or "").strip()
                if date == "" or date.lower() == "date":
                    continue

                drift_open = to_float(r.get("driftOpenHours"))
                set_open = to_float(r.get("setOpenHours"))
                drift_deliv = to_int(r.get("driftDeliveries"))
                set_deliv = to_int(r.get("setDeliveries"))

                sockeye = to_int(r.get("sockeyeDaily"))
                chinook = to_int(r.get("chinookDaily"))
                chum = to_int(r.get("chumDaily"))
                pink = to_int(r.get("pinkDaily"))
                coho = to_int(r.get("cohoDaily"))
                total = to_int(r.get("totalDaily"))

                nush_raw = r.get("nushagakHoursRaw")
                igu_raw = r.get("igushikHoursRaw")
                flags = r.get("flags")
                notes = r.get("notes")

                conn.execute(insert_sql, (
                    year, date, district_id,
                    drift_open, set_open,
                    drift_deliv, set_deliv,
                    sockeye, chinook, chum, pink, coho, total,
                    nush_raw, igu_raw,
                    flags, notes
                ))
                inserted += 1

    conn.execute("COMMIT;")
    print(f"Loaded ops_day rows: {inserted}")


# Loader for district_year_adjustment
def load_district_year_adjustments(conn: sqlite3.Connection) -> None:
    if not os.path.exists(DISTRICT_YEAR_ADJ_CSV):
        print("district_year_adjustments.csv not found (skipping).")
        return

    insert_sql = """
      INSERT OR REPLACE INTO district_year_adjustment(
        year,districtId,species,
        officialTotal,observedTotal,confidentialDelta,
        notes
      ) VALUES (?,?,?,?,?,?,?)
    """

    with open(DISTRICT_YEAR_ADJ_CSV, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            print("district_year_adjustments.csv missing header (skipping).")
            return

        conn.execute("BEGIN;")
        inserted = 0

        for r in reader:
            year = to_int(r.get("year"))
            district_key = (r.get("districtKey") or "").strip()
            species = (r.get("species") or "").strip().lower()
            if year is None or district_key == "" or species == "":
                continue

            district_id = get_or_create_district_id(conn, district_key)

            official_total = to_int(r.get("officialTotal"))
            observed_total = to_int(r.get("observedTotal"))
            conf_delta = to_int(r.get("confidentialDelta"))
            if conf_delta is None:
                # We require a delta to do anything meaningful.
                continue

            notes = (r.get("notes") or "").strip() or None

            conn.execute(
                insert_sql,
                (
                    year, district_id, species,
                    official_total, observed_total, conf_delta,
                    notes,
                ),
            )
            inserted += 1

        conn.execute("COMMIT;")
        print(f"Loaded district_year_adjustment rows: {inserted}")


def load_registration(conn: sqlite3.Connection) -> None:
    files = sorted(glob.glob(REG_GLOB))
    if not files:
        print("No registration CSVs found (skipping).")
        return

    insert_sql = """
      INSERT OR REPLACE INTO registration_day(
        year,date,districtId,
        driftPermits,dualPermits,driftBoats,
        flags,notes
      ) VALUES (?,?,?,?,?,?,?,?)
    """

    conn.execute("BEGIN;")
    inserted = 0

    for path in files:
        year = infer_year_from_path(path)

        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                continue

            for r in reader:
                date = (r.get("date") or "").strip()
                if date == "" or date.lower() == "date":
                    continue

                district_key = (r.get("districtKey") or "").strip()
                if district_key == "":
                    continue

                district_id = get_or_create_district_id(conn, district_key)

                drift_permits = to_int(r.get("driftPermits"))
                dual_permits = to_int(r.get("dualPermits"))
                drift_boats = to_int(r.get("driftBoats"))

                flags = r.get("flags")
                notes = r.get("notes")

                conn.execute(insert_sql, (
                    year, date, district_id,
                    drift_permits, dual_permits, drift_boats,
                    flags, notes
                ))
                inserted += 1

    conn.execute("COMMIT;")
    print(f"Loaded registration_day rows: {inserted}")


def load_rivers(conn: sqlite3.Connection) -> None:
    files = sorted(glob.glob(RIVER_GLOB))
    if not files:
        print("No rivers CSVs found (skipping).")
        return

    insert_sql = """
      INSERT OR REPLACE INTO river_day(
        year,date,riverId,method,
        isOperational,dailyEscapement,cumulativeEscapement,
        flags,notes
      ) VALUES (?,?,?,?,?,?,?,?,?)
    """

    conn.execute("BEGIN;")
    inserted = 0

    for path in files:
        year = infer_year_from_path(path)

        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                continue

            for r in reader:
                date = (r.get("date") or "").strip()
                if date == "" or date.lower() == "date":
                    continue

                river_key = (r.get("riverKey") or "").strip()
                method = (r.get("method") or "").strip()
                if river_key == "" or method == "":
                    continue

                river_id = get_or_create_river_id(conn, river_key)

                is_oper = to_bool_int(r.get("isOperational"))
                daily = to_int(r.get("dailyEscapement"))
                cum = to_int(r.get("cumulativeEscapement"))
                flags = r.get("flags")
                notes = r.get("notes")

                conn.execute(insert_sql, (
                    year, date, river_id, method,
                    is_oper, daily, cum,
                    flags, notes
                ))
                inserted += 1

    conn.execute("COMMIT;")
    print(f"Loaded river_day rows: {inserted}")


def find_allocation_csv() -> Optional[str]:
    for p in ALLOCATION_CSV_CANDIDATES:
        if os.path.exists(p):
            return p
    return None

def load_allocation(conn: sqlite3.Connection) -> None:
    alloc_path = find_allocation_csv()
    if not alloc_path:
        print("Allocation CSV not found (skipping).")
        return

    import json

    # Explicit mapping based on your CSV header:
    # year,naknek_kvichak_drift,naknek_kvichak_setnet_sec,naknek_kvichak_nrsha_drift,naknek_kvichak_nrsha_set,
    # egegik_drift,egegik_set,ugashik_drift,ugashik_set,nushagak_drift,nushagak_setnet_sec,nushagak_wrsha_drift,
    # nushagak_wrsha_set,togiak_drift,togiak_set,total_drift,total_set
    DISTRICT_COLS = {
        # Naknek-Kvichak: keep as-is (drift columns are correct)
        "naknek_kvichak": {
            "drift": ["naknek_kvichak_drift", "naknek_kvichak_nrsha_drift"],
            "set":   ["naknek_kvichak_setnet_sec", "naknek_kvichak_nrsha_set"],
        },

        # Egegik: CSV appears reversed in your sample (egegik_set holds drift share)
        "egegik": {
            "drift": ["egegik_set"],
            "set":   ["egegik_drift"],
        },

        # Ugashik: CSV appears reversed in your sample (ugashik_set holds drift share)
        "ugashik": {
            "drift": ["ugashik_set"],
            "set":   ["ugashik_drift"],
        },

        # Nushagak: CSV appears reversed in your sample:
        # setnet_sec + wrsha_set behave like drift components
        "nushagak": {
            "drift": ["nushagak_setnet_sec", "nushagak_wrsha_set"],
            "set":   ["nushagak_drift", "nushagak_wrsha_drift"],
        },

        # Togiak: keep as-is
        "togiak": {
            "drift": ["togiak_drift"],
            "set":   ["togiak_set"],
        },
    }

    with open(alloc_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            print("Allocation CSV has no header (skipping).")
            return

        conn.execute("BEGIN;")
        inserted = 0

        for r in reader:
            year = to_int(r.get("year"))
            if year is None:
                continue

            for district_key, mapping in DISTRICT_COLS.items():
                district_id = get_or_create_district_id(conn, district_key)

                # Sum drift components
                drift_sum = 0.0
                drift_has = False
                for col in mapping["drift"]:
                    v = to_float(r.get(col))
                    if v is None:
                        continue
                    drift_sum += v
                    drift_has = True

                # Sum set components
                set_sum = 0.0
                set_has = False
                for col in mapping["set"]:
                    v = to_float(r.get(col))
                    if v is None:
                        continue
                    set_sum += v
                    set_has = True

                drift_pct = drift_sum if drift_has else None
                set_pct = set_sum if set_has else None

                # Keep original component values for audit/debug
                components = {}
                for col in mapping["drift"] + mapping["set"]:
                    components[col] = to_float(r.get(col))

                conn.execute(
                    """
                    INSERT OR REPLACE INTO allocation_year(year,districtId,driftPct,setPct,componentsJson,notes)
                    VALUES(?,?,?,?,?,?)
                    """,
                    (year, district_id, drift_pct, set_pct, json.dumps(components, separators=(",", ":")), None)
                )
                inserted += 1

        conn.execute("COMMIT;")
        print(f"Loaded allocation_year rows: {inserted}")


def load_river_system_fva(conn: sqlite3.Connection) -> None:
    if not os.path.exists(FORECAST_VS_ACTUAL_CSV):
        print("river_system_forecast_vs_actual.csv not found (skipping).")
        return

    insert_sql = """
      INSERT OR REPLACE INTO river_system_fva(
        year, riverSystemKey,
        inshoreRunForecast,inshoreRunActual,inshoreRunPctDev,
        escapementGoalMin,escapementGoalMax,escapementGoalType,
        escapementActual,
        inshoreCatchProjected,inshoreCatchActual,inshoreCatchPctDev,
        notes
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    with open(FORECAST_VS_ACTUAL_CSV, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            print("river_system_forecast_vs_actual.csv missing header (skipping).")
            return

        conn.execute("BEGIN;")
        inserted = 0

        for r in reader:
            year = to_int(r.get("year"))
            key = (r.get("riverSystemKey") or "").strip()
            if year is None or key == "":
                continue

            conn.execute(insert_sql, (
                year, key,
                to_float(r.get("inshoreRunForecast_millions")),
                to_float(r.get("inshoreRunActual_millions")),
                to_float(r.get("inshoreRunPctDeviation")),
                to_float(r.get("escapementGoalMin_millions")),
                to_float(r.get("escapementGoalMax_millions")),
                (r.get("escapementGoalType") or "").strip() or None,
                to_float(r.get("escapementActual_millions")),
                to_float(r.get("inshoreCatchProjected_millions")),
                to_float(r.get("inshoreCatchActual_millions")),
                to_float(r.get("inshoreCatchPctDeviation")),
                (r.get("notes") or "").strip() or None,
            ))
            inserted += 1

        conn.execute("COMMIT;")
        print(f"Loaded river_system_fva rows: {inserted}")


def write_meta(conn: sqlite3.Connection) -> None:
    now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ("builtAt", now))
    conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ("schemaVersion", "1"))
    conn.commit()


def gzip_file(src: str, dst: str) -> None:
    with open(src, "rb") as f_in:
        with gzip.open(dst, "wb", compresslevel=9) as f_out:
            shutil.copyfileobj(f_in, f_out)


def main() -> None:
    ensure_dir(BUILD_DIR)
    conn = connect_db(OUT_SQLITE)
    try:
        create_schema(conn)
        load_ops(conn)
        load_district_year_adjustments(conn)
        load_registration(conn)
        load_rivers(conn)
        load_allocation(conn)
        load_river_system_fva(conn)
        write_meta(conn)
        conn.execute("PRAGMA wal_checkpoint(FULL);")
        conn.execute("PRAGMA journal_mode=DELETE;")
        conn.commit()
    finally:
        conn.close()

    if os.path.exists(OUT_GZ):
        os.remove(OUT_GZ)
    gzip_file(OUT_SQLITE, OUT_GZ)
    print("Wrote:", OUT_SQLITE)
    print("Wrote:", OUT_GZ)


if __name__ == "__main__":
    main()

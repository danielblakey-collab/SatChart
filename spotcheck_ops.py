import csv
import os
import random
from collections import defaultdict
from io import StringIO

BASE = "src/data"

ALLOWED_HEADERS = {
    "togiak": [
        ["date","districtKey","driftOpenHours","setOpenHours","driftDeliveries","setDeliveries",
         "sockeyeDaily","chinookDaily","chumDaily","pinkDaily","cohoDaily","totalDaily","notes"],
        ["date","districtKey","driftOpenHours","setOpenHours","driftDeliveries","setDeliveries",
         "sockeyeDaily","chinookDaily","chumDaily","pinkDaily","cohoDaily","totalDaily","flags","notes"],
    ],
    "ugashik": [[ "date","districtKey","driftOpenHours","setOpenHours","driftDeliveries","setDeliveries",
                 "sockeyeDaily","chinookDaily","chumDaily","pinkDaily","cohoDaily","totalDaily","notes" ]],
    "egegik": [[ "date","districtKey","driftOpenHours","setOpenHours","driftDeliveries","setDeliveries",
                "sockeyeDaily","chinookDaily","chumDaily","pinkDaily","cohoDaily","totalDaily","notes" ]],
    "naknek_kvichak": [[ "date","districtKey","driftOpenHours","setOpenHours","driftDeliveries","setDeliveries",
                        "sockeyeDaily","chinookDaily","chumDaily","pinkDaily","cohoDaily","totalDaily","notes" ]],
    "nushagak": [[ "date","districtKey","nushagakHoursRaw","igushikHoursRaw","driftOpenHours","setOpenHours",
                  "driftDeliveries","setDeliveries","sockeyeDaily","chinookDaily","chumDaily","pinkDaily",
                  "cohoDaily","totalDaily","flags","notes" ]],
}

def to_int(x):
    x = (x or "").strip()
    if x == "":
        return 0
    try:
        return int(float(x))
    except Exception:
        return None

def to_float(x):
    x = (x or "").strip()
    if x == "":
        return 0.0
    try:
        return float(x)
    except Exception:
        return None

def read_csv(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        lines = f.readlines()

    # find first non-empty
    start_idx = None
    for i, line in enumerate(lines):
        if line.strip() != "":
            start_idx = i
            break
    if start_idx is None:
        return None, [], None

    # strip BOM
    if lines[start_idx].startswith("\ufeff"):
        lines[start_idx] = lines[start_idx].lstrip("\ufeff")

    first_nonempty = lines[start_idx].strip()

    buf = StringIO("".join(lines[start_idx:]))
    reader = csv.DictReader(buf)
    rows = list(reader)
    return reader.fieldnames, rows, first_nonempty

def list_years():
    return sorted([
        d for d in os.listdir(BASE)
        if d.isdigit() and os.path.isdir(os.path.join(BASE, d))
    ])

def list_district_files(year):
    ydir = os.path.join(BASE, year)
    return [
        os.path.join(ydir, fn)
        for fn in os.listdir(ydir)
        if fn.endswith(".csv") and "_ops_" in fn
    ]

def district_from_filename(path):
    return os.path.basename(path).split("_ops_")[0]

def check_ops_file(district, path):
    issues = defaultdict(list)
    header, rows, first_nonempty = read_csv(path)

    allowed = ALLOWED_HEADERS.get(district)
    if header is None or header == []:
        issues["header_missing"].append({"found": header, "first_nonempty_line": first_nonempty})
        return issues

    if allowed and header not in allowed:
        issues["header_mismatch"].append({
            "expected_any_of": allowed,
            "found": header,
            "first_nonempty_line": first_nonempty
        })

    seen = set()
    for r in rows:
        if "date" not in r:
            continue

        # embedded header inside file
        if (r.get("sockeyeDaily") or "").strip() == "sockeyeDaily":
            issues["embedded_header_row"].append(r)
            continue

        date = (r.get("date") or "").strip()
        key = (date, (r.get("districtKey") or "").strip())
        if key in seen:
            issues["duplicate_date"].append(r)
        seen.add(key)

        notes = (r.get("notes") or "").lower()
        confidential = ("confidential" in notes) or ("not reported" in notes)

        if "totalDaily" in r and not confidential:
            s = to_int(r.get("sockeyeDaily"))
            ck = to_int(r.get("chinookDaily"))
            cm = to_int(r.get("chumDaily"))
            pk = to_int(r.get("pinkDaily"))
            co = to_int(r.get("cohoDaily"))
            total = to_int(r.get("totalDaily"))

            if None in (s, ck, cm, pk, co, total):
                issues["non_numeric_cells"].append(r)
            else:
                calc_total = s + ck + cm + pk + co
                if calc_total != total:
                    issues["species_sum_mismatch"].append({**r, "calcTotal": calc_total})

        if district == "togiak":
            total = to_int(r.get("totalDaily"))
            dho = to_float(r.get("driftOpenHours"))
            sho = to_float(r.get("setOpenHours"))
            if total is not None and total > 0 and (dho != 24 or sho != 24):
                issues["togiak_hours_not_24"].append(r)

    return issues

def main(lock_year=None):
    years = list_years()
    if not years:
        print("No year folders found under src/data")
        return

    by_district = defaultdict(list)
    for y in years:
        for p in list_district_files(y):
            d = district_from_filename(p)
            by_district[d].append((int(y), p))

    for d, entries in sorted(by_district.items()):
        if d not in ALLOWED_HEADERS:
            continue

        year, path = random.choice(entries) if lock_year is None else next(
            ((yy, pp) for (yy, pp) in entries if yy == lock_year),
            (None, None)
        )
        if year is None:
            continue

        issues = check_ops_file(d, path)
        print(f"\n{d} — {year} — {path}")
        if not issues:
            print("  ✅ no issues found")
        else:
            for k, v in issues.items():
                print(f"  ❌ {k}: {len(v)}")
                for ex in v[:2]:
                    print("     example:", ex)

if __name__ == "__main__":
    main(lock_year=None)

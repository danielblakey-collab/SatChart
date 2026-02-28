import csv, os, sys

DISTRICTS = [
    ("naknek_kvichak", "naknek_kvichak_total", "naknek_kvichak_dual"),
    ("egegik",         "egegik_total",         "egegik_dual"),
    ("ugashik",        "ugashik_total",        "ugashik_dual"),
    ("nushagak",       "nushagak_total",       "nushagak_dual"),
    ("togiak",         "togiak_total",         None),
]

def to_int(x):
    if x is None: return 0
    s = str(x).strip().replace(",", "")
    if s == "": return 0
    return int(float(s))

def main(wide_csv: str, out_csv: str):
    rows_out = []
    with open(wide_csv, newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        for row in r:
            date = (row.get("date") or "").strip()
            if date == "" or date.lower() == "date":
                continue

            for dk, total_col, dual_col in DISTRICTS:
                total = to_int(row.get(total_col))
                dual  = 0 if dual_col is None else to_int(row.get(dual_col))
                drift_boats = max(0, total - dual)

                rows_out.append({
                    "date": date,
                    "districtKey": dk,
                    "driftPermits": total,
                    "dualPermits": dual,
                    "driftBoats": drift_boats,
                    "flags": "",
                    "notes": "",
                })

    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["date","districtKey","driftPermits","dualPermits","driftBoats","flags","notes"])
        w.writeheader()
        w.writerows(rows_out)

    print("Wrote:", out_csv, "rows:", len(rows_out))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/convert_registration_wide_to_tall.py <wide.csv> <out.csv>")
        raise SystemExit(2)
    main(sys.argv[1], sys.argv[2])

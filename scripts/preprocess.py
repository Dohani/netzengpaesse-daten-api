"""
Parses Regionalszenarien_2025_Prognosen.xlsx -> data/data.json
Run once locally before deploying: python scripts/preprocess.py
"""

import json
import math
import sys
from pathlib import Path

import pandas as pd

XLSX_PATH = Path(__file__).parent.parent / "data" / "Regionalszenarien_2025_Prognosen.xlsx"
OUT_PATH = Path(__file__).parent.parent / "data" / "data.json"

REGION_SHEETS = ["Nord", "Ost", "Mitte", "West", "Südwest", "Bayern"]
YEARS = ["2024", "2030", "2035", "2045"]


def safe(v):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    if isinstance(v, float) and v == int(v):
        return int(v)
    if isinstance(v, float):
        return round(v, 4)
    return v


def parse_region_sheet(df: pd.DataFrame, region: str) -> dict:
    """
    Parse a regional sheet into:
    { operator_name: { anlagenart: { year: value } } }
    Bayern has two scenarios (Basis/Effizienz), we parse both.
    """
    raw = df.reset_index(drop=True)

    # Find header row: row where col[2] == "Bestand" or "2024"
    header_row = None
    for i, row in raw.iterrows():
        vals = [str(v).strip() for v in row.values if pd.notna(v)]
        if "2024" in vals and "2030" in vals:
            header_row = i
            break

    if header_row is None:
        return {}

    data_start = header_row + 1
    data_rows = raw.iloc[data_start:]

    is_bayern = region == "Bayern"
    operators = {}
    current_op = None

    for _, row in data_rows.iterrows():
        vals = list(row.values)
        op_cell = str(vals[0]).strip() if pd.notna(vals[0]) else ""
        art_cell = str(vals[1]).strip() if pd.notna(vals[1]) else ""

        if not art_cell or art_cell == "nan":
            continue

        if op_cell and op_cell != "nan":
            current_op = op_cell
            if current_op not in operators:
                operators[current_op] = {}

        if current_op is None:
            continue

        if not is_bayern:
            # cols: 0=operator, 1=anlagenart, 2=2024, 3=2030, 4=2035, 5=2045
            entry = {
                "2024": safe(vals[2]) if len(vals) > 2 else None,
                "2030": safe(vals[3]) if len(vals) > 3 else None,
                "2035": safe(vals[4]) if len(vals) > 4 else None,
                "2045": safe(vals[5]) if len(vals) > 5 else None,
            }
            operators[current_op][art_cell] = entry
        else:
            # Bayern: cols 2=2024, 3=Basis2030, 4=Basis2035, 5=Basis2045,
            #          7=Effizienz2030, 8=Effizienz2035, 9=Effizienz2045
            entry = {
                "2024": safe(vals[2]) if len(vals) > 2 else None,
                "basis": {
                    "2030": safe(vals[3]) if len(vals) > 3 else None,
                    "2035": safe(vals[4]) if len(vals) > 4 else None,
                    "2045": safe(vals[5]) if len(vals) > 5 else None,
                },
                "effizienz": {
                    "2030": safe(vals[7]) if len(vals) > 7 else None,
                    "2035": safe(vals[8]) if len(vals) > 8 else None,
                    "2045": safe(vals[9]) if len(vals) > 9 else None,
                },
            }
            operators[current_op][art_cell] = entry

    return operators


def parse_uebersicht(df: pd.DataFrame) -> dict:
    """
    Parse Übersicht sheet into:
    { region: { anlagenart: { vdn_2024, vdn_2030, vdn_2035, vdn_2045 } } }
    """
    raw = df.reset_index(drop=True)
    header_row = None
    for i, row in raw.iterrows():
        vals = [str(v).strip() for v in row.values if pd.notna(v)]
        if "2024" in vals and "2030" in vals:
            header_row = i
            break

    if header_row is None:
        return {}

    overview = {}
    current_region = None

    for _, row in raw.iloc[header_row + 1 :].iterrows():
        vals = list(row.values)
        reg_cell = str(vals[0]).strip() if pd.notna(vals[0]) else ""
        art_cell = str(vals[1]).strip() if pd.notna(vals[1]) else ""

        if not art_cell or art_cell == "nan":
            continue

        if reg_cell and reg_cell != "nan":
            current_region = reg_cell
            if current_region not in overview:
                overview[current_region] = {}

        if current_region is None:
            continue

        overview[current_region][art_cell] = {
            "vdn_2024": safe(vals[2]) if len(vals) > 2 else None,
            "vdn_2030": safe(vals[3]) if len(vals) > 3 else None,
            "vdn_2035": safe(vals[4]) if len(vals) > 4 else None,
            "vdn_2045": safe(vals[5]) if len(vals) > 5 else None,
        }

    return overview


def collect_anlagenarten(regions: dict) -> list:
    seen = set()
    for op_data in regions.values():
        for anlagen in op_data.values():
            seen.update(anlagen.keys())
    return sorted(seen)


def main():
    if not XLSX_PATH.exists():
        # fallback: allow passing path as argument
        if len(sys.argv) > 1:
            src = Path(sys.argv[1])
        else:
            print(f"ERROR: {XLSX_PATH} not found. Pass path as argument.")
            sys.exit(1)
    else:
        src = XLSX_PATH

    print(f"Reading {src} ...")
    xlsx = pd.read_excel(src, sheet_name=None, header=None)

    regions = {}
    for sheet_name in REGION_SHEETS:
        if sheet_name not in xlsx:
            print(f"  WARNING: sheet '{sheet_name}' not found")
            continue
        print(f"  Parsing {sheet_name} ...")
        regions[sheet_name] = parse_region_sheet(xlsx[sheet_name], sheet_name)

    print("  Parsing Übersicht ...")
    overview = parse_uebersicht(xlsx.get("Übersicht", pd.DataFrame()))

    anlagenarten = collect_anlagenarten(regions)

    payload = {
        "meta": {
            "title": "Regionalszenarien 2025 - Prognosen",
            "version": "28. Januar 2026",
            "unit": "Megawatt (MW) installierte Leistung",
            "years": YEARS,
            "regions": REGION_SHEETS,
        },
        "anlagenarten": anlagenarten,
        "overview": overview,
        "regions": regions,
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    size_kb = OUT_PATH.stat().st_size / 1024
    print(f"\nWrote {OUT_PATH} ({size_kb:.1f} KB)")
    total_ops = sum(len(v) for v in regions.values())
    print(f"  {len(regions)} regions, {total_ops} operators, {len(anlagenarten)} Anlagenarten")


if __name__ == "__main__":
    main()

"""
Lambda handler for Regionalszenarien 2025 API.
Reads data.json from S3 on cold start, caches in module scope.

Endpoints:
  GET /                                    -> API info + regions + anlagenarten
  GET /regions/{region}                    -> overview + operators list
  GET /regions/{region}/operators/{op}     -> full forecasts for one operator
  GET /forecast?region=&anlagenart=&year=  -> filtered query across all data
"""

import json
import os
import urllib.parse

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
S3_KEY = os.environ.get("S3_KEY", "data.json")

_DATA = None


def _load_data():
    global _DATA
    if _DATA is None:
        s3 = boto3.client("s3")
        obj = s3.get_object(Bucket=S3_BUCKET, Key=S3_KEY)
        _DATA = json.loads(obj["Body"].read().decode("utf-8"))
    return _DATA


def _ok(body, status=200):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _err(msg, status=404):
    return _ok({"error": msg}, status)


def _parse_path(event):
    raw = event.get("rawPath") or event.get("path") or "/"
    return [p for p in raw.strip("/").split("/") if p]


def _qs(event):
    return event.get("queryStringParameters") or {}


# ── Route handlers ─────────────────────────────────────────────────────────────


def route_root(data):
    return _ok(
        {
            "title": data["meta"]["title"],
            "version": data["meta"]["version"],
            "unit": data["meta"]["unit"],
            "regions": data["meta"]["regions"],
            "anlagenarten": data["anlagenarten"],
            "endpoints": {
                "GET /regions/{region}": "Alles für eine Region (Übersicht + alle Betreiber + Prognosen)",
                "GET /forecast?region=&anlagenart=&year=": "Gefilterter Query (alle Parameter optional)",
            },
        }
    )


def route_region(data, region):
    norm = _normalize_region(data, region)
    if not norm:
        return _err(f"Region '{region}' nicht gefunden. Verfügbar: {data['meta']['regions']}")
    return _ok(
        {
            "region": norm,
            "overview": data["overview"].get(norm, {}),
            "operators": data["regions"].get(norm, {}),
        }
    )


def route_forecast(data, qs):
    region = qs.get("region")
    anlagenart = qs.get("anlagenart")
    year = qs.get("year")

    regions_to_check = [_normalize_region(data, region)] if region else data["meta"]["regions"]
    regions_to_check = [r for r in regions_to_check if r]

    results = []
    for reg in regions_to_check:
        for op, op_data in data["regions"].get(reg, {}).items():
            anlage_keys = (
                [k for k in op_data if anlagenart.lower() in k.lower()]
                if anlagenart
                else op_data.keys()
            )
            for anlage in anlage_keys:
                entry = op_data[anlage]
                if year:
                    # Bayern has nested basis/effizienz scenarios
                    val = entry.get(year) or (entry.get("basis") or {}).get(year)
                    results.append({"region": reg, "operator": op, "anlagenart": anlage, "year": year, "value_mw": val})
                else:
                    results.append({"region": reg, "operator": op, "anlagenart": anlage, "data": entry})

    return _ok({"count": len(results), "results": results})


# ── Normalizers (case-insensitive + partial match) ─────────────────────────────


def _normalize_region(data, name):
    if not name:
        return None
    name_l = urllib.parse.unquote(name).lower()
    for r in data["meta"]["regions"]:
        if r.lower() == name_l:
            return r
    return None


# ── Router ─────────────────────────────────────────────────────────────────────


def handler(event, context):
    try:
        data = _load_data()
    except Exception as e:
        return _err(f"Daten konnten nicht geladen werden: {e}", 500)

    parts = _parse_path(event)
    qs = _qs(event)

    if not parts:
        return route_root(data)

    if len(parts) == 2 and parts[0] == "regions":
        return route_region(data, parts[1])

    if parts == ["forecast"]:
        return route_forecast(data, qs)

    return _err(f"Unbekannte Route: /{'/'.join(parts)}", 404)

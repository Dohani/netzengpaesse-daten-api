# Netzengpässe Daten API

REST API for German regional energy grid forecasts (Regionalszenarien 2025) — deployed serverless on AWS Frankfurt.

**Course:** CDUS · HSB · SoSe26

## Data

Source: [Regionalszenarien 2025 – Prognosen](https://www.netztransparenz.de) (CC BY 4.0)

- 6 planning regions: Nord, Ost, Mitte, West, Südwest, Bayern
- 89 network operators
- 18 installation types (PV, Wind, Heat Pumps, EV, Batteries, ...)
- Forecast years: 2024 · 2030 · 2035 · 2045

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | API info, regions, and installation types |
| `GET` | `/regions/{region}` | Full data for a region (overview + all operators + forecasts) |
| `GET` | `/forecast?region=&anlagenart=&year=` | Filtered query — all params optional |

## Usage

```bash
# API info
curl https://gsvbolvm3b.execute-api.eu-central-1.amazonaws.com/

# All data for a region
curl https://gsvbolvm3b.execute-api.eu-central-1.amazonaws.com/regions/Nord

# Filter by installation type and year
curl "https://gsvbolvm3b.execute-api.eu-central-1.amazonaws.com/forecast?region=Nord&anlagenart=Windenergie%20an%20Land&year=2045"
```

## Deploy

Requires AWS CLI configured (`aws configure`) and Python 3.

```bash
bash deploy.sh
```

Creates: S3 bucket → uploads data → IAM role → Lambda (Python 3.12) → API Gateway HTTP v2.

## Architecture

```
Excel → scripts/preprocess.py → data/data.json → S3
                                                    ↓
                              API Gateway → Lambda (handler.py)
```

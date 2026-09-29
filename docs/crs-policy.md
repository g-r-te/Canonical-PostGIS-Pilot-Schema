# CRS policy

## Decision

| Layer                 | CRS                                          | Enforced by |
|-----------------------|----------------------------------------------|-------------|
| Source delivery       | whatever the source uses, **declared** in `source_run.source_srid` | `source_run.source_srid` FK → `spatial_ref_sys`; promotion rejects rows whose SRID differs |
| Staging (`iris_staging.*.geom`) | source CRS, untransformed          | promotion check |
| **Core storage** (`iris_core.*.geom`) | **EPSG:3035 — ETRS89 / LAEA Europe**, metres | `geometry(<Type>, 3035)` typmod |
| Measurement           | planar in EPSG:3035 (m, m²)                  | all derivation SQL |
| Exchange / output     | EPSG:4326 (GeoJSON, RFC 7946), transformed on read | `ST_Transform(geom, 4326)` in queries |

## Why EPSG:3035 for storage

* **One CRS for every country.** The schema is country-aware and must accept DE, NL and later
  countries without per-country geometry columns or partitions with different SRIDs. A single
  pan-European CRS keeps `geom` one typed column and keeps cross-border joins (a substation
  just across a regional border) trivially correct.
* **Equal-area.** The peatland vertical is driven by areas (overlap m² × 8 eco-points/m²).
  Lambert Azimuthal Equal-Area preserves area, so `ST_Area(geom)` is the ellipsoidal area
  without a geography cast. `sql/verify/02_spatial_round_trip.sql` checks this against
  `ST_Area(geography)` (relative difference < 1e‑5).
* **Metric units.** `ST_DWithin(geom, geom, 20000)` means 20 km, and GiST indexes on `geom`
  serve both KNN (`<->`) and radius searches for the BESS vertical.
* **Official.** EPSG:3035 is the INSPIRE / EEA reference grid CRS, so EU-level screening layers
  (Natura 2000, CORINE, EEA grids) are commonly published in it.

## Known trade-off: distances

LAEA preserves area, not distance. Scale distortion is zero at the projection centre
(52°N, 10°E) and grows with distance from it. It is small across the pilot regions (Bavaria,
Friesland), which is acceptable for **screening** distances (nearest substation, "within 20 km").

Distances are therefore labelled with their method in `evidence.method`
(`planar EPSG:3035`). If a use case needs survey-grade distances, compute them on the fly with
`ST_Distance(ST_Transform(a, 4326)::geography, ST_Transform(b, 4326)::geography)` or in the
national CRS; do not change the storage CRS.

## Rules

1. `geom` is the only geometry column name in the core contract. A column named `geometry`
   is forbidden (checked by `sql/verify/01_contract.sql` and a unit test).
2. Every core geometry has an explicit type and SRID in its typmod; untyped `geometry` exists
   only in staging and in `evidence.geom` (which is `geometry(Geometry, 3035)`: any type, fixed SRID).
3. A missing SRID (0) or a SRID that contradicts the declared source CRS is a **rejection**,
   never a guess.
4. Z/M dimensions are rejected rather than silently dropped.
5. Invalid geometries are rejected with `ST_IsValidReason`; they are not auto-repaired with
   `ST_MakeValid`, because repair can change area and topology. Repair belongs in the source
   adapter, where it can be recorded.
6. Polygons are promoted to `MultiPolygon` (`ST_Multi`) so that one column type fits single and
   multi-part parcels.

## Fixture coverage

| Fixture                                     | Delivered in       |
|---------------------------------------------|--------------------|
| `fixtures/de/*.geojson`                     | EPSG:4326 (RFC 7946 GeoJSON) |
| `fixtures/de/substations_epsg25832.csv`     | EPSG:25832 (ETRS89 / UTM 32N, German official) |
| `fixtures/nl/*_epsg28992.csv`               | EPSG:28992 (Amersfoort / RD New, Dutch official) |

All three are normalised to EPSG:3035 in core, and the round-trip check reads every promoted
feature back in its source CRS and compares it with what was delivered.

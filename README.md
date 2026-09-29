# IRIS-CAND-03: Canonical PostGIS Pilot Schema

A minimal, reproducible PostgreSQL 16 / PostGIS 3.4 schema for the IRIS pilot. It covers staging
and core schemas, country-scoped keys, a documented CRS policy, source metadata, controlled
promotion, explainable screening evidence for the **BESS** and **peatland** verticals, seed
fixtures, verification queries and automated tests.

```text
fixtures (4326 / 25832 / 28992) ──seed──▶ iris_staging ──promote_*()──▶ iris_core ──derive_evidence()──▶ evidence ──▶ pilot views
```

## Quick start

Requirements: Docker (for PostgreSQL 16 + PostGIS 3.4) and Python 3.12+.

```bash
docker compose up -d --wait
```

Install into a virtual environment. Debian/Ubuntu block system-wide `pip install`
(`error: externally-managed-environment`, PEP 668), and a venv keeps the project isolated
everywhere else too. On Debian/Ubuntu, install `python3-venv` first if `venv` is missing.

```bash
python3 -m venv .venv
```

```bash
source .venv/bin/activate
```

On Windows (PowerShell), activate with `.venv\Scripts\Activate.ps1` instead.

```bash
python -m pip install -e ".[dev]"
```

```bash
iris-db rebuild --yes
```

```bash
python -m pytest
```

`rebuild` drops the project schemas, applies every migration, loads the DE and NL fixtures through
staging and promotion, derives evidence, and runs the verification queries. It exits non-zero if
any check fails. The same steps one at a time:

| Command                  | What it does |
|--------------------------|--------------|
| `iris-db migrate`        | Apply pending migrations in `migrations/` (idempotent, checksummed) |
| `iris-db status`         | Show applied / pending migrations |
| `iris-db seed`           | Load `fixtures/*/manifest.json` → staging → core, then derive evidence (idempotent) |
| `iris-db verify`         | Run `sql/verify/*.sql` and print PASS/FAIL per check |
| `iris-db reset --yes`    | Drop `iris_core`, `iris_staging`, `iris_meta` (keeps the postgis extension) |
| `iris-db rebuild --yes`  | reset → migrate → seed → verify |

`python -m iris_schema <command>` works the same way. A `Makefile` wraps these commands
(`make up rebuild test`).

**Configuration.** `IRIS_DATABASE_URL` (default `postgresql://iris:iris@localhost:55432/iris`)
and `IRIS_TEST_DATABASE_URL` (default `.../iris_test`, created by `docker-compose`).
The credentials are local development values only; no external services or secrets are used.
`reset` refuses non-local hosts unless `IRIS_ALLOW_REMOTE_RESET=1`.

**Using your own PostgreSQL.** Any PostgreSQL 16+ with PostGIS 3.4+ available works. The first
migration runs `CREATE EXTENSION IF NOT EXISTS postgis`, so the role needs permission to create it
(or it must already exist). Point the two URLs at it.

## Repository layout

```text
migrations/          Forward-only SQL migrations (the schema), applied in order
  0001_extensions_and_schemas.sql   postgis, schemas, domains (ISO country/region codes)
  0002_core_reference.sql           country, region (country-scoped PK)
  0003_core_source_run.sql          source metadata: vintage, CRS, completeness, accuracy
  0004_core_entities.sql            parcel, substation, peatland, screening_layer + indexes
  0005_core_evidence.sql            explainable screening facts + indexes
  0006_staging.sql                  permissive landing tables
  0007_promotion.sql                validation + promotion functions
  0008_derive_evidence.sql          BESS / peatland / constraint evidence derivation
  0009_pilot_views.sql              v_bess_screening, v_peatland_screening, disclaimer
sql/verify/          Verification queries (run by `iris-db verify`, also psql-runnable)
sql/queries/         Example pilot queries (BESS candidates, peatland candidates, explain a parcel)
sql/screening/       Live, index-backed screening query patterns
fixtures/de/         Synthetic DE-BY vertical slice (GeoJSON 4326 + CSV in EPSG:25832)
fixtures/nl/         Synthetic NL-FR set in EPSG:28992 (proves country/CRS awareness)
src/iris_schema/     CLI, migration runner, fixture loader, verifier
tests/               pytest suite (unit tests + database tests)
docs/                schema diagram, CRS policy, design decisions
```

## Schema at a glance

Full Mermaid ER diagram: [docs/schema.md](docs/schema.md).

| Table                         | Geometry (`geom`)            | Natural key                                   |
|-------------------------------|------------------------------|-----------------------------------------------|
| `iris_core.source_run`        | none (declares `source_srid`)| `(country_code, source_id, source_date)`      |
| `iris_core.parcel`            | `MultiPolygon, 3035`         | `(country_code, cadastral_ref)`               |
| `iris_core.substation`        | `Point, 3035`                | `(country_code, source_id, source_feature_id)`|
| `iris_core.peatland`          | `MultiPolygon, 3035`         | `(country_code, source_id, source_feature_id)`|
| `iris_core.screening_layer`   | `MultiPolygon, 3035`         | `(country_code, source_id, source_feature_id)`|
| `iris_core.evidence`          | `Geometry, 3035` (nullable)  | `(country_code, run, parcel, vertical, type, related feature)` |
| `iris_staging.{parcel,substation,peatland,screening_layer}` | untyped, source CRS | none (raw) |

Canonical names `geom`, `country_code`, `region_code`, `source_id`, `source_date`, `created_at`
exist on every core entity. No column is named `geometry`.

### Key and constraint design

* **Country-scoped identity.** Every business table has `PRIMARY KEY (country_code, <entity>_id)`,
  and every FK between business tables includes `country_code`. The database, not convention,
  guarantees that joins never cross countries. This also permits later `LIST` partitioning by country.
* **`country_code` is `NOT NULL` everywhere**, in staging too, and is an ISO 3166-1 alpha-2 domain
  with a FK to `iris_core.country`.
* **Regions are country-scoped.** `region` has PK `(country_code, region_code)` plus a prefix
  CHECK, so `(country_code, region_code)` FKs make a "DE row in NL-FR" impossible.
* **Lineage cannot drift.** `source_id` and `source_date` are carried on each entity (canonical
  query fields) and enforced by one composite FK `(country_code, source_run_id, source_id,
  source_date)` to `source_run`.
* **Geometry contract.** Typmod fixes type and SRID. `CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))`
  holds on every core table.
* **Evidence contract.** `evidence_type` fixes the vertical, the related feature (exactly one) and
  the unit. Eco-point rows must state `eco_points_per_m2` in `assumptions`. Units are explicit
  (`m`, `m2`, `eco_points`) and measured columns carry unit suffixes (`area_m2`, `voltage_kv`).

Rationale and the production roadmap: [docs/design-decisions.md](docs/design-decisions.md).

### CRS policy (summary)

Sources arrive in their own CRS, declared in `source_run.source_srid` and kept as-is in staging.
Core stores everything in **EPSG:3035 (ETRS89-LAEA)**: one metric, equal-area, pan-European CRS,
so area-based eco-point estimates are exact and all countries share one typed `geom` column.
Output is GeoJSON in EPSG:4326 via `ST_Transform` on read. LAEA does not preserve distance, but
the distortion is small at pilot scale and every distance is labelled with its method. See
[docs/crs-policy.md](docs/crs-policy.md).

### Indexes for the two verticals

| Query shape                                      | Index |
|--------------------------------------------------|-------|
| BESS: nearest substation (`ORDER BY geom <-> …`), radius (`ST_DWithin`) | `substation_geom_gist` |
| BESS: voltage filter                             | `substation_country_voltage_ix` |
| Peatland: parcel ∩ peatland (`ST_Intersects`)    | `peatland_geom_gist`, `parcel_geom_gist` |
| Constraints: parcel ∩ screening layer            | `screening_layer_geom_gist` |
| One-region slice                                 | `*_country_region_ix` |
| Parcel lookup by cadastral reference             | `parcel_cadastral_ref_uq` |
| Evidence per parcel / per region & type          | `evidence_parcel_ix`, `evidence_region_type_ix` |
| FK support (source runs, related features)       | `*_source_run_ix`, partial `evidence_*_ix` |
| Promotion work queue                             | `iris_staging.*_run_status_ix` |

## Controlled promotion

`iris_staging.promote_<entity>(country_code, source_run_id)` validates every pending row and
records the result per row:

| Check | Example `reject_reason` |
|-------|-------------------------|
| geometry present, SRID declared and equal to `source_run.source_srid` | `geom SRID 4326 does not match source_run.source_srid 25832` |
| 2D, expected type family, valid (also after transform) | `geom invalid: Self-intersection[…]` |
| `source_feature_id` present and unique in the run | `source_feature_id duplicated within source run` |
| `region_code` present (where required) and known for the country | `region_code missing` |
| required / numeric attributes, vocabularies | `peat_class swamp not in (bog, fen, transition)` |

Valid rows are transformed to EPSG:3035 and upserted on `(country_code, source_id,
source_feature_id)`. Counts are written back to `source_run`. The committed fixtures deliberately
include four bad rows (bow-tie polygon, missing region, unknown peat class, missing coordinates),
and `iris-db seed` prints them:

```text
-- DE
source_id                          entity            run  staged  promoted  rejected
de-by-cadastre-synthetic           parcel              1       6         4         2
    rejected DEBY-SYN-P005: geom invalid: Self-intersection[11.632 48.3015]
    rejected DEBY-SYN-P006: region_code missing
...
```

## Screening evidence and pilot queries

`iris_core.derive_evidence(country, region, as_of_date [, max_substation_distance_m, eco_points_per_m2])`
is recorded as its own `source_run` (`run_kind = 'derive'`) and writes one evidence row per fact:

* `substation_proximity` (bess): distance to the nearest substation within the search radius (KNN).
* `peatland_overlap` (peatland): overlap area in m².
* `eco_point_estimate` (peatland): overlap m² × 8, with the factor and its "not certified" basis in `assumptions`.
* `screening_overlap` (per applicable vertical): overlap with constraint layers.

Pilot views read the latest derive run:

```bash
psql "postgresql://iris:iris@localhost:55432/iris" -f sql/queries/bess_candidates.sql
```

```bash
psql "postgresql://iris:iris@localhost:55432/iris" -f sql/queries/peatland_candidates.sql
```

Without a local `psql`, use `docker compose exec -T db psql -U iris -d iris < sql/queries/bess_candidates.sql`.
Both views carry the project's uncertainty wording in `uncertainty_note`. **Outputs are indicative
screening material: not a permit, reservation, grid-capacity statement or certified compensation.**

## Verification (acceptance criteria)

`iris-db verify` runs `sql/verify/*.sql`. Every file is plain SQL, runs in a rolled-back
transaction, and returns `(check_name, ok, detail)`.

| Acceptance criterion | Evidence |
|---|---|
| 1. Rebuilds from an empty DB without manual intervention | `iris-db rebuild --yes`; `tests/test_rebuild.py::test_rebuild_from_empty_database` creates a brand-new database (no postgis, no schemas) and runs migrate → seed → verify |
| 2. Required pilot fields exist with canonical names | `01_contract.sql`: all 6 canonical columns on all 5 core entities, no `geometry` column, geometry typmods |
| 3. `country_code` cannot be null | `01_contract.sql` (every table in both schemas); `test_constraints.py` (declared NOT NULL, inserts rejected in core and staging) |
| 4. Spatial round trip and index usage | `02_spatial_round_trip.sql` (GeoJSON 4326 → 3035 → 4326 within 1e-8° (≈1 mm), area preserved, every fixture feature round-trips from its source CRS); `03_index_usage.sql` (at realistic volume and default planner settings, EXPLAIN shows the expected GiST/B-tree index for each pilot query shape) |

Index-usage note: on 6-row fixture tables every plan costs about the same, so EXPLAIN there
proves nothing. `03_index_usage.sql` therefore generates a realistic volume *inside its rolled-back
transaction* (20 000 parcels, 2 000 substations, 2 000 peatlands, 500 constraint polygons,
20 000 evidence rows), runs `ANALYZE`, and then checks with **default planner settings** that
each pilot query shape uses its intended index. It also checks that KNN ordering is pushed into
the GiST index (`Order By`). The run takes about 2 s.

## Tests

```bash
python -m pytest -v
```

* **Unit tests** (no database): migration discovery, ordering and checksum rules; manifest
  validation; CSV/GeoJSON/WKT adapters (blank cells stay unknown).
* **Database tests**: constraint enforcement (null/invalid country, cross-country FKs, region
  scoping, per-country uniqueness, lineage drift, SRID/type/validity/emptiness, evidence
  contract), promotion rejections and idempotency, derived evidence values, spatial round trip,
  index usage, rebuild from an empty database, migration idempotency, drift detection and
  atomicity.

Database tests run against `IRIS_TEST_DATABASE_URL`. If it is unreachable they are **skipped**
with a clear reason. CI sets `IRIS_REQUIRE_DB=1` so they fail there instead. CI
(`.github/workflows/ci.yml`) runs lint, `iris-db rebuild --yes` and the full suite against a
`postgis/postgis:16-3.4` service.

## Fixtures

All fixture data is **synthetic** (CC0) and deterministic. None of it is real cadastral, grid or
environmental data.

* `fixtures/de/`: the one-region vertical slice (DE-BY near 48.3°N 11.6°E). 6 parcels (4 valid),
  3 peatlands (2 valid), 4 substations in EPSG:25832 (3 valid, one with unknown voltage),
  2 screening features (a regional Natura 2000 exclusion and a national flood-zone restriction
  that applies to both verticals).
* `fixtures/nl/`: 2 parcels, 1 peatland, 1 substation in EPSG:28992 (RD New), region NL-FR.

Each `manifest.json` declares, per source, `source_id`, `source_date`, `srid`, `format`, region,
licence, completeness and positional accuracy. Adding a country means adding a manifest plus its
`country`/`region` rows. No code changes are needed.

## Assumptions

* The pilot slice is one region (DE-BY). NL exists only to prove the design is country- and
  CRS-aware.
* Region codes are ISO 3166-2. Cadastral references are unique within a country.
* One `source_run` per `(country, source, vintage)`. Re-loading a vintage replaces its staged rows
  and upserts core rows.
* "Nearest substation" means the planar distance from the parcel boundary to the substation
  point in EPSG:3035, searched within 20 km (configurable). Substations with unknown voltage are
  kept (NULL), not dropped or guessed.
* The 8 eco-points/m² factor is a parameter recorded on every eco-point evidence row, not a
  constant baked into the schema.

## Deliberate simplifications

Summarised here; details and the production path are in
[docs/design-decisions.md](docs/design-decisions.md#deliberate-simplifications-and-how-they-evolve).

* Core keeps the current version of each feature. It has no validity periods and does not
  retire features missing from a newer vintage.
* Substations are points. Grid capacity is out of scope.
* Countries and regions are seeded by a migration rather than loaded from a reference source.
* It has no roles or row-level security, and no partitioning. The composite keys are
  partition-ready.
* A small in-repo migration runner is used instead of Alembic/Flyway. The migrations are plain
  SQL and portable.

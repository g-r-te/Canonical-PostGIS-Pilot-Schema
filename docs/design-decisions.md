# Design decisions

Short ADR-style notes: the decision, why, and how it evolves for production.

## 1. Country-scoped composite primary keys

**Decision.** Every business table has `PRIMARY KEY (country_code, <entity>_id)` with an identity
`<entity>_id`, and every FK between business tables includes `country_code`.

**Why.** "Identifiers and joins must be country-scoped" is enforced by the database, not by
convention: a DE evidence row physically cannot reference an NL substation, and a DE parcel cannot
claim an NL source run (see `test_constraints.py`). It also keeps the door open for
`PARTITION BY LIST (country_code)`, since a partitioned table's PK must contain the partition key.

**Trade-off.** Composite FKs are wider than a single `bigint`. At pilot scale that is negligible,
and it removes an entire class of cross-country join bugs.

## 2. Natural keys alongside surrogate keys

| Table              | Natural / upsert key                                  |
|--------------------|-------------------------------------------------------|
| `parcel`           | `(country_code, cadastral_ref)` and `(country_code, source_id, source_feature_id)` |
| other entities     | `(country_code, source_id, source_feature_id)`        |
| `source_run`       | `(country_code, source_id, source_date)`: one run per source vintage |
| `evidence`         | `(country_code, source_run_id, parcel_id, vertical, evidence_type, related feature)` with `NULLS NOT DISTINCT` |
| `region`           | `(country_code, region_code)`                         |

The `source_feature_id` key makes promotion an idempotent upsert, and the vintage key makes
re-seeding reuse the same run instead of piling up duplicates.

## 3. Denormalised lineage enforced by one composite FK

Entities carry `source_id` and `source_date` (canonical names the pilot queries need) *and*
`source_run_id`. Consistency is guaranteed by
`FOREIGN KEY (country_code, source_run_id, source_id, source_date) REFERENCES source_run (...)`,
so the copies can never drift from the run they claim to come from.

## 4. Region scoping

`region` has PK `(country_code, region_code)` and a CHECK that `region_code` starts with
`country_code || '-'`. Any FK to it therefore proves the region belongs to the row's country.
`evidence.region_code` is tied to the parcel's region by FK `(country_code, region_code, parcel_id)`
with `ON UPDATE CASCADE`.

`region_code` is `NOT NULL` for parcels, substations and peatlands (inherently regional) and
nullable for `screening_layer` and `source_run`, where `NULL` explicitly means *national extent*.

## 5. Staging → core promotion lives in SQL

**Decision.** Validation and promotion are plpgsql functions (`iris_staging.promote_*`), not Python.

**Why.** The rules sit next to the constraints they protect, work for any client (Python loader,
`psql`, a future orchestrator), and run set-based inside one transaction per source run. Staging
checks turn row-level problems into `rejected` rows with a reason; the core constraints remain
the final authority, so anything that slips through fails the batch loudly.

## 6. Nothing is invented

* Blank attributes stay `NULL` (`voltage_kv`, `peat_class`, `positional_accuracy_m`).
* Missing or undeclared geometry is rejected, not defaulted.
* Invalid geometry is rejected, not `ST_MakeValid`-ed.
* The eco-point factor is recorded per evidence row in `assumptions` together with the wording
  "current commercial baseline, not certified compensation". The pilot views expose the
  project's uncertainty wording as `uncertainty_note`.

## 7. Vocabularies as CHECK constraints, not ENUM types

Small vocabularies (`run_kind`, `completeness`, `layer_category`, `vertical`, `evidence_type`,
`metric_unit`) are `text` + `CHECK`. They are easier to evolve in a migration than `ENUM`s, whose
values cannot be removed. Countries and regions are reference **tables**, because they carry
data and are FK targets.

## 8. Minimal forward-only migration runner

A ~150-line runner (`src/iris_schema/migrations.py`) instead of Alembic/Flyway: plain SQL files,
one transaction per migration, an advisory lock, and checksums (LF-normalised so Windows
checkouts don't register as drift). The migrations are plain SQL and can move to
Flyway/sqitch/Alembic unchanged.

## Deliberate simplifications and how they evolve

| Simplification (pilot)                                    | Production evolution |
|-----------------------------------------------------------|----------------------|
| Core holds the **current** version of each feature; features that disappear from a later vintage are not retired. | Add `valid_from`/`valid_to` (or a `retired_by_run_id`) and close out features absent from a complete (`completeness = 'complete'`) run. |
| Substations are points.                                   | Add an optional footprint polygon and line/cable entities when grid-capacity data arrives. |
| Evidence derivation is a single SQL function run per region. | Move to an orchestrated job (one run per region/vertical) with run-level parameters stored on `source_run`. |
| Validation O(n²) duplicate-property check in staging.     | Replace with a window function / temp unique index for large batches. |
| Reference data (countries, regions) seeded in a migration. | Load from an ISO 3166 reference source with its own `source_run`. |
| No row-level security or roles.                           | Separate owner / loader / reader roles; loaders write staging only; `iris_core` writes only via `SECURITY DEFINER` promotion functions. |
| Single database, no partitioning.                         | `PARTITION BY LIST (country_code)` on large tables (the composite PKs already allow it). |
| Planar distances in EPSG:3035.                            | Keep; compute geodesic distances on demand where precision matters (see `crs-policy.md`). |
| No `updated_at` trigger; the upsert sets it.              | Add a trigger, or audit/history tables if change tracking is required. |

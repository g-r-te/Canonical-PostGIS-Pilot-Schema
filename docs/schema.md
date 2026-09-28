# Schema diagram

Three schemas:

| Schema         | Role                                                                                   |
|----------------|----------------------------------------------------------------------------------------|
| `iris_staging` | Raw landing zone. Features as delivered: any geometry type, in the source CRS, jsonb attributes. |
| `iris_core`    | Canonical, strictly typed, country-scoped entities. `geom` is typed and stored in EPSG:3035. |
| `iris_meta`    | Migration bookkeeping (`schema_migration`). Created by the migration runner.         |

## iris_core

`PK` / `FK` / `UK` markers show key membership. Every foreign key between business entities
includes `country_code`, so a row can only ever reference rows of its own country.

```mermaid
erDiagram
    country ||--o{ region : "has"
    country ||--o{ source_run : "scopes"
    region  |o--o{ source_run : "optional extent"
    region  ||--o{ parcel : "(country_code, region_code)"
    region  ||--o{ substation : ""
    region  ||--o{ peatland : ""
    region  |o--o{ screening_layer : "NULL = national layer"

    source_run ||--o{ parcel : "(country_code, source_run_id, source_id, source_date)"
    source_run ||--o{ substation : "lineage FK"
    source_run ||--o{ peatland : "lineage FK"
    source_run ||--o{ screening_layer : "lineage FK"
    source_run ||--o{ evidence : "derive run"

    parcel ||--o{ evidence : "(country_code, region_code, parcel_id)"
    substation |o--o{ evidence : "(country_code, substation_id)"
    peatland |o--o{ evidence : "(country_code, peatland_id)"
    screening_layer |o--o{ evidence : "(country_code, screening_layer_id)"

    country {
        text country_code PK "ISO 3166-1 alpha-2"
        text name
        timestamptz created_at
    }
    region {
        text country_code PK,FK
        text region_code PK "ISO 3166-2, prefix = country_code"
        text name
        timestamptz created_at
    }
    source_run {
        text country_code PK,FK
        bigint source_run_id PK "identity"
        text region_code FK "nullable"
        text source_id UK "UK (country_code, source_id, source_date)"
        date source_date UK "vintage of the data"
        text run_kind "ingest | derive"
        int source_srid FK "spatial_ref_sys"
        text completeness "complete | partial | unknown"
        numeric positional_accuracy_m "NULL = not stated"
        text status "loading | promoted | failed"
        int rows_staged
        int rows_promoted
        int rows_rejected
        timestamptz created_at
    }
    parcel {
        text country_code PK,FK
        bigint parcel_id PK
        text region_code FK
        text cadastral_ref UK "UK (country_code, cadastral_ref)"
        text land_use
        geometry geom "MultiPolygon, 3035"
        float area_m2 "generated ST_Area(geom)"
        bigint source_run_id FK
        text source_id FK
        date source_date FK
        text source_feature_id UK "UK (country_code, source_id, source_feature_id)"
        timestamptz created_at
    }
    substation {
        text country_code PK,FK
        bigint substation_id PK
        text region_code FK
        text name
        text operator
        numeric voltage_kv "NULL = not stated"
        geometry geom "Point, 3035"
        bigint source_run_id FK
        text source_id FK
        date source_date FK
        text source_feature_id UK
        timestamptz created_at
    }
    peatland {
        text country_code PK,FK
        bigint peatland_id PK
        text region_code FK
        text peat_class "bog | fen | transition | NULL"
        geometry geom "MultiPolygon, 3035"
        float area_m2 "generated"
        bigint source_run_id FK
        text source_id FK
        date source_date FK
        text source_feature_id UK
        timestamptz created_at
    }
    screening_layer {
        text country_code PK,FK
        bigint screening_layer_id PK
        text region_code FK "nullable"
        text layer_code "e.g. natura2000"
        text layer_category "exclusion | restriction | information"
        text_array applies_to "subset of {bess, peatland}"
        text feature_name
        geometry geom "MultiPolygon, 3035"
        bigint source_run_id FK
        text source_id FK
        date source_date FK
        text source_feature_id UK
        timestamptz created_at
    }
    evidence {
        text country_code PK,FK
        bigint evidence_id PK
        text region_code FK "= parcel region (FK)"
        bigint parcel_id FK
        text vertical "bess | peatland"
        text evidence_type "substation_proximity | peatland_overlap | eco_point_estimate | screening_overlap"
        bigint substation_id FK "exactly one related"
        bigint peatland_id FK "feature is set"
        bigint screening_layer_id FK
        numeric metric_value ">= 0"
        text metric_unit "m | m2 | eco_points"
        text method
        jsonb assumptions "e.g. eco_points_per_m2"
        geometry geom "Geometry, 3035, nullable"
        bigint source_run_id FK
        text source_id FK
        date source_date FK
        timestamptz created_at
    }
```

## iris_staging

`parcel`, `substation`, `peatland`, `screening_layer` share one shape:

```mermaid
erDiagram
    source_run ||--o{ staging_feature : "(country_code, source_run_id) ON DELETE CASCADE"
    staging_feature {
        bigint staging_id PK
        text country_code FK "NOT NULL"
        bigint source_run_id FK "NOT NULL"
        text source_feature_id "raw"
        text region_code "raw, validated at promotion"
        jsonb properties "raw attributes"
        geometry geom "untyped, SRID = source_run.source_srid"
        text load_status "pending | validated | promoted | rejected"
        text reject_reason "required iff rejected"
        timestamptz loaded_at
        timestamptz promoted_at
        timestamptz created_at
    }
```

## Data flow

```mermaid
flowchart LR
    F["fixtures/&lt;cc&gt;/*.geojson / *.csv<br/>(source CRS: 4326, 25832, 28992)"]
    -->|iris-db seed<br/>ST_SetSRID(source_srid)| S["iris_staging.*<br/>load_status = pending"]
    S -->|"promote_*()<br/>validate → reject with reason<br/>ST_Transform → 3035, upsert"| C["iris_core entities"]
    C -->|"derive_evidence()<br/>KNN / ST_Intersects in 3035"| E["iris_core.evidence"]
    E --> V["v_bess_screening<br/>v_peatland_screening"]
```

## Pilot query surface

| View                              | Grain                | Key columns |
|-----------------------------------|----------------------|-------------|
| `iris_core.v_bess_screening`      | one row per parcel   | `nearest_substation_distance_m`, `nearest_substation_voltage_kv`, `exclusion_overlap_m2`, `restriction_overlap_m2`, `constraint_layers` |
| `iris_core.v_peatland_screening`  | one row per parcel   | `peatland_overlap_m2`, `peatland_overlap_ratio`, `eco_points_estimate`, `restriction_overlap_m2`, `exclusion_overlap_m2` |

Both also expose the canonical `country_code`, `region_code`, `source_id`, `source_date`, `geom`
and the project's `uncertainty_note`, and read only the latest derive run per country/region.

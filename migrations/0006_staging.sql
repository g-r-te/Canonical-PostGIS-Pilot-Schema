-- 0006: staging (landing) tables.
--
-- Staging is deliberately permissive about content and strict about provenance:
--   * geom is untyped geometry: any type, delivered in the source CRS (SRID must equal
--     source_run.source_srid; checked at promotion, because the SRID is part of the data contract).
--   * region_code and attributes are raw text/jsonb, validated at promotion time.
--   * country_code and source_run_id are NOT NULL: a staged row is always attributable to one
--     country-scoped run, so rejected rows can be reported back to the adapter that produced them.
--   * load_status / reject_reason record the outcome of promotion explicitly per row.

CREATE TABLE iris_staging.parcel (
    staging_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       iris_core.iso_country_code NOT NULL,
    source_run_id      bigint      NOT NULL,
    source_feature_id  text,
    region_code        text,
    properties         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    geom               geometry,
    load_status        text        NOT NULL DEFAULT 'pending'
                       CHECK (load_status IN ('pending', 'validated', 'promoted', 'rejected')),
    reject_reason      text,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    promoted_at        timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (country_code, source_run_id)
        REFERENCES iris_core.source_run (country_code, source_run_id) ON DELETE CASCADE,
    CHECK ((load_status = 'rejected') = (reject_reason IS NOT NULL))
);

CREATE TABLE iris_staging.substation      (LIKE iris_staging.parcel INCLUDING ALL);
CREATE TABLE iris_staging.peatland        (LIKE iris_staging.parcel INCLUDING ALL);
CREATE TABLE iris_staging.screening_layer (LIKE iris_staging.parcel INCLUDING ALL);

-- LIKE ... INCLUDING ALL copies defaults, identity, CHECKs and indexes but not foreign keys.
ALTER TABLE iris_staging.substation ADD FOREIGN KEY (country_code, source_run_id)
    REFERENCES iris_core.source_run (country_code, source_run_id) ON DELETE CASCADE;
ALTER TABLE iris_staging.peatland ADD FOREIGN KEY (country_code, source_run_id)
    REFERENCES iris_core.source_run (country_code, source_run_id) ON DELETE CASCADE;
ALTER TABLE iris_staging.screening_layer ADD FOREIGN KEY (country_code, source_run_id)
    REFERENCES iris_core.source_run (country_code, source_run_id) ON DELETE CASCADE;

CREATE INDEX parcel_run_status_ix          ON iris_staging.parcel          (country_code, source_run_id, load_status);
CREATE INDEX substation_run_status_ix      ON iris_staging.substation      (country_code, source_run_id, load_status);
CREATE INDEX peatland_run_status_ix        ON iris_staging.peatland        (country_code, source_run_id, load_status);
CREATE INDEX screening_layer_run_status_ix ON iris_staging.screening_layer (country_code, source_run_id, load_status);

COMMENT ON TABLE iris_staging.parcel IS 'Raw parcel features as delivered, in source CRS. Promoted by iris_staging.promote_parcel().';

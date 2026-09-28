-- 0004: canonical spatial entities for the BESS and peatland pilot verticals.
--
-- Shared contract for every table in this file:
--   * PRIMARY KEY (country_code, <entity>_id): identifiers are country-scoped, and the table can
--     later be LIST-partitioned by country_code (a partitioned PK must contain the partition key).
--   * geom has an explicit geometry type and SRID 3035; the typmod rejects anything else.
--   * geom must be valid and non-empty (CHECK). Repair happens upstream and is never silent here.
--   * Source lineage (source_run_id, source_id, source_date) is enforced by one composite FK,
--     so the denormalised source_id/source_date can never drift from the source_run row.
--   * (country_code, source_id, source_feature_id) is the idempotent upsert key for promotion.

------------------------------------------------------------------------------------------------
-- parcel: cadastral land parcels (candidate sites for both verticals)
------------------------------------------------------------------------------------------------
CREATE TABLE iris_core.parcel (
    parcel_id          bigint GENERATED ALWAYS AS IDENTITY,
    country_code       iris_core.iso_country_code  NOT NULL,
    region_code        iris_core.iso_region_code   NOT NULL,
    cadastral_ref      text        NOT NULL CHECK (btrim(cadastral_ref) <> ''),
    land_use           text,
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    area_m2            double precision GENERATED ALWAYS AS (ST_Area(geom)) STORED,
    source_run_id      bigint      NOT NULL,
    source_id          iris_core.source_identifier NOT NULL,
    source_date        date        NOT NULL,
    source_feature_id  text        NOT NULL CHECK (btrim(source_feature_id) <> ''),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, parcel_id),
    CONSTRAINT parcel_region_scoped_uq  UNIQUE (country_code, region_code, parcel_id),
    CONSTRAINT parcel_cadastral_ref_uq  UNIQUE (country_code, cadastral_ref),
    CONSTRAINT parcel_source_feature_uq UNIQUE (country_code, source_id, source_feature_id),
    CONSTRAINT parcel_region_fk FOREIGN KEY (country_code, region_code)
        REFERENCES iris_core.region (country_code, region_code),
    CONSTRAINT parcel_source_run_fk FOREIGN KEY (country_code, source_run_id, source_id, source_date)
        REFERENCES iris_core.source_run (country_code, source_run_id, source_id, source_date),
    CONSTRAINT parcel_geom_valid CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

COMMENT ON TABLE  iris_core.parcel IS 'Cadastral parcel. Natural key: (country_code, cadastral_ref).';
COMMENT ON COLUMN iris_core.parcel.area_m2 IS 'Planar area in m2; exact because EPSG:3035 is equal-area.';

CREATE INDEX parcel_geom_gist         ON iris_core.parcel USING gist (geom);
CREATE INDEX parcel_country_region_ix ON iris_core.parcel (country_code, region_code);
CREATE INDEX parcel_source_run_ix     ON iris_core.parcel (country_code, source_run_id);

------------------------------------------------------------------------------------------------
-- substation: grid connection points (BESS vertical)
------------------------------------------------------------------------------------------------
CREATE TABLE iris_core.substation (
    substation_id      bigint GENERATED ALWAYS AS IDENTITY,
    country_code       iris_core.iso_country_code  NOT NULL,
    region_code        iris_core.iso_region_code   NOT NULL,
    name               text,
    operator           text,
    voltage_kv         numeric     CHECK (voltage_kv > 0),   -- NULL = not stated by the source
    geom               geometry(Point, 3035) NOT NULL,
    source_run_id      bigint      NOT NULL,
    source_id          iris_core.source_identifier NOT NULL,
    source_date        date        NOT NULL,
    source_feature_id  text        NOT NULL CHECK (btrim(source_feature_id) <> ''),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, substation_id),
    CONSTRAINT substation_source_feature_uq UNIQUE (country_code, source_id, source_feature_id),
    CONSTRAINT substation_region_fk FOREIGN KEY (country_code, region_code)
        REFERENCES iris_core.region (country_code, region_code),
    CONSTRAINT substation_source_run_fk FOREIGN KEY (country_code, source_run_id, source_id, source_date)
        REFERENCES iris_core.source_run (country_code, source_run_id, source_id, source_date),
    CONSTRAINT substation_geom_valid CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

COMMENT ON COLUMN iris_core.substation.voltage_kv IS 'Nominal voltage in kV. NULL when the source does not state it.';

CREATE INDEX substation_geom_gist          ON iris_core.substation USING gist (geom);
CREATE INDEX substation_country_region_ix  ON iris_core.substation (country_code, region_code);
CREATE INDEX substation_country_voltage_ix ON iris_core.substation (country_code, voltage_kv);
CREATE INDEX substation_source_run_ix      ON iris_core.substation (country_code, source_run_id);

------------------------------------------------------------------------------------------------
-- peatland: mapped peat soils (peatland / eco-point vertical)
------------------------------------------------------------------------------------------------
CREATE TABLE iris_core.peatland (
    peatland_id        bigint GENERATED ALWAYS AS IDENTITY,
    country_code       iris_core.iso_country_code  NOT NULL,
    region_code        iris_core.iso_region_code   NOT NULL,
    peat_class         text        CHECK (peat_class IN ('bog', 'fen', 'transition')),  -- NULL = unclassified
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    area_m2            double precision GENERATED ALWAYS AS (ST_Area(geom)) STORED,
    source_run_id      bigint      NOT NULL,
    source_id          iris_core.source_identifier NOT NULL,
    source_date        date        NOT NULL,
    source_feature_id  text        NOT NULL CHECK (btrim(source_feature_id) <> ''),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, peatland_id),
    CONSTRAINT peatland_source_feature_uq UNIQUE (country_code, source_id, source_feature_id),
    CONSTRAINT peatland_region_fk FOREIGN KEY (country_code, region_code)
        REFERENCES iris_core.region (country_code, region_code),
    CONSTRAINT peatland_source_run_fk FOREIGN KEY (country_code, source_run_id, source_id, source_date)
        REFERENCES iris_core.source_run (country_code, source_run_id, source_id, source_date),
    CONSTRAINT peatland_geom_valid CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

CREATE INDEX peatland_geom_gist         ON iris_core.peatland USING gist (geom);
CREATE INDEX peatland_country_region_ix ON iris_core.peatland (country_code, region_code);
CREATE INDEX peatland_source_run_ix     ON iris_core.peatland (country_code, source_run_id);

------------------------------------------------------------------------------------------------
-- screening_layer: constraint polygons (protected areas, flood zones, ...) used for screening
------------------------------------------------------------------------------------------------
CREATE TABLE iris_core.screening_layer (
    screening_layer_id bigint GENERATED ALWAYS AS IDENTITY,
    country_code       iris_core.iso_country_code  NOT NULL,
    region_code        iris_core.iso_region_code,             -- NULL = national-extent layer
    layer_code         text        NOT NULL CHECK (layer_code ~ '^[a-z0-9][a-z0-9_]*$'),
    layer_category     text        NOT NULL
                       CHECK (layer_category IN ('exclusion', 'restriction', 'information')),
    applies_to         text[]      NOT NULL
                       CHECK (cardinality(applies_to) > 0
                              AND applies_to <@ ARRAY['bess', 'peatland']::text[]),
    feature_name       text,
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    source_run_id      bigint      NOT NULL,
    source_id          iris_core.source_identifier NOT NULL,
    source_date        date        NOT NULL,
    source_feature_id  text        NOT NULL CHECK (btrim(source_feature_id) <> ''),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, screening_layer_id),
    CONSTRAINT screening_layer_source_feature_uq UNIQUE (country_code, source_id, source_feature_id),
    CONSTRAINT screening_layer_region_fk FOREIGN KEY (country_code, region_code)
        REFERENCES iris_core.region (country_code, region_code),
    CONSTRAINT screening_layer_source_run_fk FOREIGN KEY (country_code, source_run_id, source_id, source_date)
        REFERENCES iris_core.source_run (country_code, source_run_id, source_id, source_date),
    CONSTRAINT screening_layer_geom_valid CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

COMMENT ON COLUMN iris_core.screening_layer.applies_to IS
    'Pilot verticals this constraint is relevant to: bess and/or peatland.';

CREATE INDEX screening_layer_geom_gist         ON iris_core.screening_layer USING gist (geom);
CREATE INDEX screening_layer_country_layer_ix  ON iris_core.screening_layer (country_code, layer_code);
CREATE INDEX screening_layer_country_region_ix ON iris_core.screening_layer (country_code, region_code);
CREATE INDEX screening_layer_source_run_ix     ON iris_core.screening_layer (country_code, source_run_id);

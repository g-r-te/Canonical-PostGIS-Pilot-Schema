-- 0005: evidence, the explainable output of spatial screening.
--
-- One row = one measured fact about one parcel for one vertical, e.g.
--   "parcel 12 is 842.1 m from substation 3"            (bess,     substation_proximity)
--   "parcel 12 overlaps peatland 7 by 10 512 m2"        (peatland, peatland_overlap)
--   "... which is 84 096 eco-points at 8 pts/m2"        (peatland, eco_point_estimate)
--   "parcel 12 overlaps a natura2000 area by 1 200 m2"  (bess,     screening_overlap)
--
-- Every row names exactly one related feature, carries an explicit unit, the method used and
-- the assumptions applied, so that any number in a prospecting output can be traced back.

CREATE TABLE iris_core.evidence (
    evidence_id         bigint GENERATED ALWAYS AS IDENTITY,
    country_code        iris_core.iso_country_code  NOT NULL,
    region_code         iris_core.iso_region_code   NOT NULL,
    parcel_id           bigint      NOT NULL,
    vertical            text        NOT NULL CHECK (vertical IN ('bess', 'peatland')),
    evidence_type       text        NOT NULL CHECK (evidence_type IN (
                            'substation_proximity', 'peatland_overlap',
                            'eco_point_estimate', 'screening_overlap')),
    substation_id       bigint,
    peatland_id         bigint,
    screening_layer_id  bigint,
    metric_value        numeric     NOT NULL CHECK (metric_value >= 0),
    metric_unit         text        NOT NULL CHECK (metric_unit IN ('m', 'm2', 'eco_points')),
    method              text        NOT NULL,
    assumptions         jsonb       NOT NULL DEFAULT '{}'::jsonb
                        CHECK (jsonb_typeof(assumptions) = 'object'),
    geom                geometry(Geometry, 3035),     -- NULL only when the fact has no spatial footprint
    source_run_id       bigint      NOT NULL,
    source_id           iris_core.source_identifier NOT NULL,
    source_date         date        NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, evidence_id),

    -- Parcel FK includes region_code so evidence.region_code is provably the parcel's region.
    CONSTRAINT evidence_parcel_fk FOREIGN KEY (country_code, region_code, parcel_id)
        REFERENCES iris_core.parcel (country_code, region_code, parcel_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    -- Related features are country-scoped but may lie in a neighbouring region.
    CONSTRAINT evidence_substation_fk FOREIGN KEY (country_code, substation_id)
        REFERENCES iris_core.substation (country_code, substation_id) ON DELETE CASCADE,
    CONSTRAINT evidence_peatland_fk FOREIGN KEY (country_code, peatland_id)
        REFERENCES iris_core.peatland (country_code, peatland_id) ON DELETE CASCADE,
    CONSTRAINT evidence_screening_layer_fk FOREIGN KEY (country_code, screening_layer_id)
        REFERENCES iris_core.screening_layer (country_code, screening_layer_id) ON DELETE CASCADE,
    CONSTRAINT evidence_source_run_fk FOREIGN KEY (country_code, source_run_id, source_id, source_date)
        REFERENCES iris_core.source_run (country_code, source_run_id, source_id, source_date),

    CONSTRAINT evidence_exactly_one_related_feature
        CHECK (num_nonnulls(substation_id, peatland_id, screening_layer_id) = 1),
    -- Shape of each evidence type: vertical, related feature and unit must agree.
    CONSTRAINT evidence_type_contract CHECK (
        CASE evidence_type
            WHEN 'substation_proximity' THEN vertical = 'bess'     AND substation_id IS NOT NULL AND metric_unit = 'm'
            WHEN 'peatland_overlap'     THEN vertical = 'peatland' AND peatland_id   IS NOT NULL AND metric_unit = 'm2'
            WHEN 'eco_point_estimate'   THEN vertical = 'peatland' AND peatland_id   IS NOT NULL AND metric_unit = 'eco_points'
                                             AND assumptions ? 'eco_points_per_m2'
            WHEN 'screening_overlap'    THEN screening_layer_id IS NOT NULL AND metric_unit = 'm2'
        END
    ),
    CONSTRAINT evidence_geom_valid CHECK (geom IS NULL OR (ST_IsValid(geom) AND NOT ST_IsEmpty(geom)))
);

-- One fact per (run, parcel, vertical, type, related feature). NULLS NOT DISTINCT (PG15+) makes
-- the two NULL related-feature columns participate in uniqueness.
CREATE UNIQUE INDEX evidence_fact_uq ON iris_core.evidence
    (country_code, source_run_id, parcel_id, vertical, evidence_type,
     substation_id, peatland_id, screening_layer_id) NULLS NOT DISTINCT;

CREATE INDEX evidence_parcel_ix        ON iris_core.evidence (country_code, parcel_id, vertical);
CREATE INDEX evidence_region_type_ix   ON iris_core.evidence (country_code, region_code, vertical, evidence_type);
CREATE INDEX evidence_substation_ix    ON iris_core.evidence (country_code, substation_id) WHERE substation_id IS NOT NULL;
CREATE INDEX evidence_peatland_ix      ON iris_core.evidence (country_code, peatland_id) WHERE peatland_id IS NOT NULL;
CREATE INDEX evidence_screening_ix     ON iris_core.evidence (country_code, screening_layer_id) WHERE screening_layer_id IS NOT NULL;
CREATE INDEX evidence_source_run_ix    ON iris_core.evidence (country_code, source_run_id);
CREATE INDEX evidence_geom_gist        ON iris_core.evidence USING gist (geom) WHERE geom IS NOT NULL;

COMMENT ON TABLE iris_core.evidence IS
    'Explainable screening facts. Indicative only: not a permit, reservation or certified compensation.';

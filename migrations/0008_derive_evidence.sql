-- 0008: deterministic derivation of screening evidence for one country/region.
--
-- A derivation is itself recorded as a source_run (run_kind = 'derive'), so every evidence row
-- has the same lineage contract as ingested data. Re-running for the same (country, region,
-- as-of date) replaces that run's evidence for the region: the operation is idempotent.
--
-- All measurements are planar in EPSG:3035 (metres / square metres). Areas are exact (equal-area
-- projection); distances carry the small LAEA scale distortion documented in docs/crs-policy.md.

CREATE FUNCTION iris_core.derive_evidence(
    p_country_code               text,
    p_region_code                text,
    p_as_of_date                 date,
    p_max_substation_distance_m  numeric DEFAULT 20000,
    p_eco_points_per_m2          numeric DEFAULT 8
)
RETURNS TABLE (evidence_type text, row_count integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    c_source_id constant text := 'iris-screening-v1';
    v_run_id    bigint;
BEGIN
    IF p_max_substation_distance_m IS NULL OR p_max_substation_distance_m <= 0 THEN
        RAISE EXCEPTION 'p_max_substation_distance_m must be > 0';
    END IF;
    IF p_eco_points_per_m2 IS NULL OR p_eco_points_per_m2 <= 0 THEN
        RAISE EXCEPTION 'p_eco_points_per_m2 must be > 0';
    END IF;

    INSERT INTO iris_core.source_run AS sr
           (country_code, region_code, source_id, source_date, run_kind, source_srid,
            completeness, status, notes)
    VALUES (p_country_code, p_region_code, c_source_id, p_as_of_date, 'derive', 3035,
            'unknown', 'loading', 'Derived screening evidence (iris_core.derive_evidence)')
    ON CONFLICT ON CONSTRAINT source_run_vintage_uq
       DO UPDATE SET status = 'loading', updated_at = now()
    RETURNING sr.source_run_id INTO v_run_id;

    DELETE FROM iris_core.evidence e
     WHERE e.country_code = p_country_code AND e.source_run_id = v_run_id
       AND e.region_code = p_region_code;

    -- BESS: nearest substation per parcel (index-assisted KNN, bounded by ST_DWithin).
    INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
                                    substation_id, metric_value, metric_unit, method, assumptions, geom,
                                    source_run_id, source_id, source_date)
    SELECT p.country_code, p.region_code, p.parcel_id, 'bess', 'substation_proximity',
           n.substation_id, round(n.distance_m::numeric, 2), 'm',
           'ST_Distance(parcel.geom, substation.geom), planar EPSG:3035, nearest within search radius',
           jsonb_build_object('max_search_distance_m', p_max_substation_distance_m,
                              'voltage_kv', n.voltage_kv),
           CASE WHEN n.distance_m = 0 THEN ST_ClosestPoint(p.geom, n.geom)
                ELSE ST_ShortestLine(p.geom, n.geom) END,
           v_run_id, c_source_id, p_as_of_date
      FROM iris_core.parcel p
      CROSS JOIN LATERAL (
            SELECT s.substation_id, s.geom, s.voltage_kv, ST_Distance(p.geom, s.geom) AS distance_m
              FROM iris_core.substation s
             WHERE s.country_code = p.country_code
               AND ST_DWithin(s.geom, p.geom, p_max_substation_distance_m)
             ORDER BY s.geom <-> p.geom, s.substation_id
             LIMIT 1
      ) n
     WHERE p.country_code = p_country_code AND p.region_code = p_region_code;

    -- Peatland: overlap area and indicative eco-point estimate per (parcel, peatland).
    WITH overlap AS (
        SELECT p.country_code, p.region_code, p.parcel_id, pl.peatland_id,
               ST_Multi(ST_CollectionExtract(ST_Intersection(p.geom, pl.geom), 3)) AS g
          FROM iris_core.parcel p
          JOIN iris_core.peatland pl
            ON pl.country_code = p.country_code AND ST_Intersects(p.geom, pl.geom)
         WHERE p.country_code = p_country_code AND p.region_code = p_region_code
    ),
    overlap_rows AS (
        INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
                                        peatland_id, metric_value, metric_unit, method, geom,
                                        source_run_id, source_id, source_date)
        SELECT o.country_code, o.region_code, o.parcel_id, 'peatland', 'peatland_overlap',
               o.peatland_id, round(ST_Area(o.g)::numeric, 2), 'm2',
               'ST_Area(ST_Intersection(parcel.geom, peatland.geom)), EPSG:3035 (equal-area)',
               o.g, v_run_id, c_source_id, p_as_of_date
          FROM overlap o
         WHERE NOT ST_IsEmpty(o.g) AND ST_Area(o.g) > 0
        RETURNING country_code, region_code, parcel_id, peatland_id, metric_value
    )
    INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
                                    peatland_id, metric_value, metric_unit, method, assumptions,
                                    source_run_id, source_id, source_date)
    SELECT o.country_code, o.region_code, o.parcel_id, 'peatland', 'eco_point_estimate',
           o.peatland_id, round(o.metric_value * p_eco_points_per_m2, 2), 'eco_points',
           'peatland_overlap_m2 * eco_points_per_m2',
           jsonb_build_object('eco_points_per_m2', p_eco_points_per_m2,
                              'overlap_m2', o.metric_value,
                              'basis', 'current commercial baseline, not certified compensation'),
           v_run_id, c_source_id, p_as_of_date
      FROM overlap_rows o;

    -- Screening constraints: overlap per (parcel, layer feature, applicable vertical).
    INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
                                    screening_layer_id, metric_value, metric_unit, method, assumptions,
                                    geom, source_run_id, source_id, source_date)
    SELECT o.country_code, o.region_code, o.parcel_id, v.vertical, 'screening_overlap',
           o.screening_layer_id, round(ST_Area(o.g)::numeric, 2), 'm2',
           'ST_Area(ST_Intersection(parcel.geom, screening_layer.geom)), EPSG:3035 (equal-area)',
           jsonb_build_object('layer_code', o.layer_code, 'layer_category', o.layer_category),
           o.g, v_run_id, c_source_id, p_as_of_date
      FROM (
            SELECT p.country_code, p.region_code, p.parcel_id, sl.screening_layer_id,
                   sl.layer_code, sl.layer_category, sl.applies_to,
                   ST_Multi(ST_CollectionExtract(ST_Intersection(p.geom, sl.geom), 3)) AS g
              FROM iris_core.parcel p
              JOIN iris_core.screening_layer sl
                ON sl.country_code = p.country_code AND ST_Intersects(p.geom, sl.geom)
             WHERE p.country_code = p_country_code AND p.region_code = p_region_code
      ) o
      CROSS JOIN LATERAL unnest(o.applies_to) AS v(vertical)
     WHERE NOT ST_IsEmpty(o.g) AND ST_Area(o.g) > 0;

    UPDATE iris_core.source_run sr
       SET status = 'promoted',
           rows_promoted = (SELECT count(*) FROM iris_core.evidence e
                             WHERE e.country_code = p_country_code AND e.source_run_id = v_run_id),
           updated_at = now()
     WHERE sr.country_code = p_country_code AND sr.source_run_id = v_run_id;

    RETURN QUERY
        SELECT e.evidence_type, count(*)::int
          FROM iris_core.evidence e
         WHERE e.country_code = p_country_code AND e.source_run_id = v_run_id
           AND e.region_code = p_region_code
         GROUP BY e.evidence_type
         ORDER BY e.evidence_type;
END
$$;

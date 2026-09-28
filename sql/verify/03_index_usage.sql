-- Acceptance criterion 4 (part 2): the pilot query shapes are served by the intended indexes.
--
-- On the 6-row fixture tables every plan costs about the same, so EXPLAIN there proves nothing.
-- This file therefore first generates a realistic synthetic volume INSIDE the verification
-- transaction (which the verifier always rolls back):
--     20 000 parcels, 2 000 substations, 2 000 peatlands, 500 screening features, 20 000 evidence rows
-- then ANALYZEs them and asks the planner, with default settings (no enable_* overrides), how it
-- would execute each pilot query shape.

INSERT INTO iris_core.source_run (country_code, region_code, source_id, source_date, source_srid, status)
VALUES ('DE', 'DE-BY', 'verify-index-volume', DATE '1999-12-31', 3035, 'promoted');

CREATE TEMP TABLE bulk_run ON COMMIT DROP AS
SELECT country_code, source_run_id, source_id, source_date
  FROM iris_core.source_run
 WHERE country_code = 'DE' AND source_id = 'verify-index-volume';

-- 200 x 100 grid of 100 m parcels around (4 430 000, 2 820 000) in EPSG:3035.
INSERT INTO iris_core.parcel (country_code, region_code, cadastral_ref, geom,
                              source_run_id, source_id, source_date, source_feature_id)
SELECT r.country_code, 'DE-BY', 'BULK-' || g, ST_Multi(ST_MakeEnvelope(x, y, x + 95, y + 95, 3035)),
       r.source_run_id, r.source_id, r.source_date, 'bulk-p-' || g
  FROM bulk_run r,
       generate_series(0, 19999) AS g,
       LATERAL (SELECT 4400000 + (g % 200) * 100 AS x, 2800000 + (g / 200) * 100 AS y) c;

INSERT INTO iris_core.substation (country_code, region_code, voltage_kv, geom,
                                  source_run_id, source_id, source_date, source_feature_id)
SELECT r.country_code, 'DE-BY', CASE WHEN g % 3 = 0 THEN 380 ELSE 110 END,
       ST_SetSRID(ST_MakePoint(4400000 + (g % 50) * 400 + 50, 2800000 + (g / 50) * 250 + 50), 3035),
       r.source_run_id, r.source_id, r.source_date, 'bulk-s-' || g
  FROM bulk_run r, generate_series(0, 1999) AS g;

INSERT INTO iris_core.peatland (country_code, region_code, peat_class, geom,
                                source_run_id, source_id, source_date, source_feature_id)
SELECT r.country_code, 'DE-BY', 'fen',
       ST_Multi(ST_MakeEnvelope(4400000 + (g % 50) * 400, 2800000 + (g / 50) * 250,
                                4400000 + (g % 50) * 400 + 150, 2800000 + (g / 50) * 250 + 120, 3035)),
       r.source_run_id, r.source_id, r.source_date, 'bulk-m-' || g
  FROM bulk_run r, generate_series(0, 1999) AS g;

INSERT INTO iris_core.screening_layer (country_code, region_code, layer_code, layer_category, applies_to,
                                       geom, source_run_id, source_id, source_date, source_feature_id)
SELECT r.country_code, 'DE-BY', 'natura2000', 'exclusion', ARRAY['bess'],
       ST_Multi(ST_MakeEnvelope(4400000 + (g % 25) * 800, 2800000 + (g / 25) * 500,
                                4400000 + (g % 25) * 800 + 200, 2800000 + (g / 25) * 500 + 200, 3035)),
       r.source_run_id, r.source_id, r.source_date, 'bulk-n-' || g
  FROM bulk_run r, generate_series(0, 499) AS g;

-- Representative statistics, as production tables would have. ANALYZE is allowed inside a
-- transaction; the rolled-back rows are cleaned up by autovacuum like any aborted load.
ANALYZE iris_core.parcel, iris_core.substation, iris_core.peatland, iris_core.screening_layer;

CREATE TEMP TABLE bulk_substation ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY s.substation_id) - 1 AS k, s.substation_id
  FROM iris_core.substation s
  JOIN bulk_run r ON s.country_code = r.country_code AND s.source_id = r.source_id;

INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
                                substation_id, metric_value, metric_unit, method,
                                source_run_id, source_id, source_date)
SELECT p.country_code, p.region_code, p.parcel_id, 'bess', 'substation_proximity',
       b.substation_id, 100, 'm', 'verify volume',
       r.source_run_id, r.source_id, r.source_date
  FROM bulk_run r
  JOIN iris_core.parcel p ON p.country_code = r.country_code AND p.source_id = r.source_id
  JOIN bulk_substation b ON b.k = p.parcel_id % 2000;

ANALYZE iris_core.evidence;

CREATE FUNCTION pg_temp.plan_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    plan json;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) ' || q INTO plan;
    RETURN plan::text;
END
$$;

WITH probe(check_name, expected_index, must_contain, query) AS (
    VALUES
    ('BESS: nearest substation (KNN, distance ordering pushed into GiST)',
     'substation_geom_gist', '"Order By"',
     $q$SELECT s.substation_id
          FROM iris_core.substation s
         WHERE s.country_code = 'DE'
         ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(4410000, 2810000), 3035)
         LIMIT 1$q$),

    ('BESS: substations within radius (ST_DWithin)',
     'substation_geom_gist', NULL,
     $q$SELECT substation_id FROM iris_core.substation s
         WHERE ST_DWithin(s.geom, ST_SetSRID(ST_MakePoint(4410000, 2810000), 3035), 1000)$q$),

    ('Peatland: peatlands intersecting a parcel (ST_Intersects)',
     'peatland_geom_gist', NULL,
     $q$SELECT pl.peatland_id
          FROM iris_core.parcel p
          JOIN iris_core.peatland pl
            ON pl.country_code = p.country_code AND ST_Intersects(pl.geom, p.geom)
         WHERE p.country_code = 'DE' AND p.cadastral_ref = 'BULK-4321'$q$),

    ('Screening: constraint layers intersecting a parcel',
     'screening_layer_geom_gist', NULL,
     $q$SELECT sl.screening_layer_id
          FROM iris_core.parcel p
          JOIN iris_core.screening_layer sl
            ON sl.country_code = p.country_code AND ST_Intersects(sl.geom, p.geom)
         WHERE p.country_code = 'DE' AND p.cadastral_ref = 'BULK-4321'$q$),

    ('Spatial window: parcels in a bounding box',
     'parcel_geom_gist', NULL,
     $q$SELECT parcel_id FROM iris_core.parcel
         WHERE geom && ST_MakeEnvelope(4405000, 2805000, 4406000, 2806000, 3035)$q$),

    ('Region slice: parcels of one country/region',
     'parcel_country_region_ix', NULL,
     $q$SELECT parcel_id FROM iris_core.parcel WHERE country_code = 'DE' AND region_code = 'DE-BW'$q$),

    ('Natural key: parcel by country-scoped cadastral_ref',
     'parcel_cadastral_ref_uq', NULL,
     $q$SELECT parcel_id FROM iris_core.parcel
         WHERE country_code = 'DE' AND cadastral_ref = 'DEBY-0917-0001'$q$),

    ('Evidence: facts for one parcel and vertical',
     'evidence_parcel_ix', NULL,
     $q$SELECT evidence_type, metric_value FROM iris_core.evidence
         WHERE country_code = 'DE' AND parcel_id = 42 AND vertical = 'bess'$q$)
),
planned AS (
    SELECT check_name, expected_index, must_contain, pg_temp.plan_of(query) AS plan FROM probe
)
SELECT check_name || ' [' || (SELECT count(*) FROM iris_core.parcel) || ' parcels]' AS check_name,
       plan LIKE '%"Index Name": "' || expected_index || '"%'
           AND (must_contain IS NULL OR plan LIKE '%' || must_contain || '%') AS ok,
       'expected ' || expected_index || coalesce(' + ' || must_contain, '') || '; plan uses: '
       || coalesce((SELECT string_agg(DISTINCT m[1], ', ')
                      FROM regexp_matches(plan, '"Index Name": "([^"]+)"', 'g') AS m),
                   'no index (sequential scan)') AS detail
  FROM planned;

-- Acceptance criterion 4 (part 1): spatial round trip.
--
--  Tolerance ~1 mm: 1e-8 deg for geographic CRSs, 1e-3 m for projected CRSs. The double
--  transformation source -> 3035 -> source is not bit-exact.
--  Fixture features are compared in their *own* source CRS. Comparing them in EPSG:4326 would
--  add an unrelated datum transformation (e.g. RD New/Bessel -> WGS84 for EPSG:28992) whose
--  PROJ pipeline depends on the installed proj-data grids, making the check environment-dependent.
--  a) Write a GeoJSON polygon (EPSG:4326) through the canonical contract into iris_core.parcel
--     (stored as EPSG:3035), read it back as GeoJSON in EPSG:4326 and compare with the input.
--  b) Every promoted fixture feature, read back from iris_core in its source CRS, matches what
--     was delivered to staging (covers the EPSG:4326, EPSG:25832 and EPSG:28992 fixtures).
--
-- Runs inside a transaction that the verifier always rolls back.

INSERT INTO iris_core.source_run (country_code, region_code, source_id, source_date, source_srid, status)
VALUES ('DE', 'DE-BY', 'verify-round-trip', DATE '1999-12-31', 4326, 'promoted');

CREATE TEMP TABLE rt_input ON COMMIT DROP AS
SELECT '{"type":"Polygon","coordinates":[[[11.5,48.1],[11.51,48.1],[11.51,48.107],[11.5,48.107],[11.5,48.1]]]}'::text AS geojson;

INSERT INTO iris_core.parcel (country_code, region_code, cadastral_ref, geom,
                              source_run_id, source_id, source_date, source_feature_id)
SELECT r.country_code, r.region_code, 'VERIFY-RT-0001',
       ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(i.geojson), 4326), 3035)),
       r.source_run_id, r.source_id, r.source_date, 'verify-rt-0001'
  FROM iris_core.source_run r, rt_input i
 WHERE r.country_code = 'DE' AND r.source_id = 'verify-round-trip';

WITH synthetic AS (
    SELECT ST_GeomFromGeoJSON(i.geojson)                                    AS original,
           ST_GeomFromGeoJSON(ST_AsGeoJSON(ST_Transform(p.geom, 4326), 12)) AS returned,
           p.area_m2,
           ST_Area(ST_GeomFromGeoJSON(i.geojson)::geography)                AS geodesic_area_m2,
           ST_SRID(p.geom)                                                  AS stored_srid
      FROM iris_core.parcel p, rt_input i
     WHERE p.country_code = 'DE' AND p.cadastral_ref = 'VERIFY-RT-0001'
),
fixture AS (
    SELECT s.country_code, s.source_feature_id,
           ST_HausdorffDistance(ST_Transform(c.geom, ST_SRID(s.geom)), ST_Multi(s.geom)) AS deviation,
           ST_SRID(s.geom) AS source_srid
      FROM iris_staging.parcel s
      JOIN iris_core.source_run r ON r.country_code = s.country_code AND r.source_run_id = s.source_run_id
      JOIN iris_core.parcel c
        ON c.country_code = s.country_code AND c.source_id = r.source_id
       AND c.source_feature_id = s.source_feature_id
     WHERE s.load_status = 'promoted'
    UNION ALL
    SELECT s.country_code, s.source_feature_id,
           ST_HausdorffDistance(ST_Transform(c.geom, ST_SRID(s.geom)), s.geom),
           ST_SRID(s.geom)
      FROM iris_staging.substation s
      JOIN iris_core.source_run r ON r.country_code = s.country_code AND r.source_run_id = s.source_run_id
      JOIN iris_core.substation c
        ON c.country_code = s.country_code AND c.source_id = r.source_id
       AND c.source_feature_id = s.source_feature_id
     WHERE s.load_status = 'promoted'
    UNION ALL
    SELECT s.country_code, s.source_feature_id,
           ST_HausdorffDistance(ST_Transform(c.geom, ST_SRID(s.geom)), ST_Multi(s.geom)),
           ST_SRID(s.geom)
      FROM iris_staging.peatland s
      JOIN iris_core.source_run r ON r.country_code = s.country_code AND r.source_run_id = s.source_run_id
      JOIN iris_core.peatland c
        ON c.country_code = s.country_code AND c.source_id = r.source_id
       AND c.source_feature_id = s.source_feature_id
     WHERE s.load_status = 'promoted'
),
fixture_checked AS (
    SELECT f.*,
           CASE WHEN srs.proj4text LIKE '+proj=longlat%' THEN 1e-8 ELSE 1e-3 END AS tolerance,
           CASE WHEN srs.proj4text LIKE '+proj=longlat%' THEN 'deg' ELSE 'm' END AS unit
      FROM fixture f
      JOIN spatial_ref_sys srs ON srs.srid = f.source_srid
),
fixture_unit AS (
    SELECT unit, max(deviation) AS max_deviation
      FROM fixture_checked
     GROUP BY unit
)
SELECT 'round trip: GeoJSON 4326 -> core 3035 -> GeoJSON 4326' AS check_name,
       stored_srid = 3035 AND ST_HausdorffDistance(original, returned) < 1e-8
           AND ST_NPoints(original) = ST_NPoints(returned) AS ok,
       format('stored SRID %s, max vertex deviation %s deg, %s vertices in / %s out',
              stored_srid, ST_HausdorffDistance(original, returned),
              ST_NPoints(original), ST_NPoints(returned)) AS detail
  FROM synthetic
UNION ALL
SELECT 'round trip: equal-area storage preserves area',
       abs(area_m2 - geodesic_area_m2) / geodesic_area_m2 < 1e-5,
       format('area_m2 (EPSG:3035) = %s, geodesic area = %s, relative diff = %s',
              round(area_m2::numeric, 3), round(geodesic_area_m2::numeric, 3),
              abs(area_m2 - geodesic_area_m2) / geodesic_area_m2)
  FROM synthetic
UNION ALL
SELECT 'round trip: every promoted fixture feature matches its staged source geometry',
       count(*) > 0 AND bool_and(deviation < tolerance),
       format('%s features (%s) compared in source CRS (%s), max deviation %s',
              count(*), string_agg(DISTINCT country_code, '+'),
              string_agg(DISTINCT 'EPSG:' || source_srid, ', '),
              (SELECT string_agg(max_deviation || ' ' || unit, ', ' ORDER BY unit) FROM fixture_unit))
  FROM fixture_checked;

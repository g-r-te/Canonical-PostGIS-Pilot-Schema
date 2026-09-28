-- Pilot query surface and deterministic fixture expectations (after `iris-db seed`).

WITH bess AS (SELECT * FROM iris_core.v_bess_screening WHERE country_code = 'DE' AND region_code = 'DE-BY'),
peat AS (SELECT * FROM iris_core.v_peatland_screening WHERE country_code = 'DE' AND region_code = 'DE-BY'),
rejected AS (
    SELECT 'parcel' AS entity, source_feature_id, reject_reason FROM iris_staging.parcel WHERE load_status = 'rejected'
    UNION ALL SELECT 'substation', source_feature_id, reject_reason FROM iris_staging.substation WHERE load_status = 'rejected'
    UNION ALL SELECT 'peatland', source_feature_id, reject_reason FROM iris_staging.peatland WHERE load_status = 'rejected'
    UNION ALL SELECT 'screening_layer', source_feature_id, reject_reason FROM iris_staging.screening_layer WHERE load_status = 'rejected'
),
runs AS (
    SELECT count(*) FILTER (WHERE status <> 'promoted') AS not_promoted, count(*) AS total
      FROM iris_core.source_run
)
SELECT 'BESS pilot view: every DE-BY parcel has a nearest substation' AS check_name,
       count(*) = 4 AND count(nearest_substation_distance_m) = 4 AS ok,
       format('%s parcels, %s with distance; distances (m): %s', count(*), count(nearest_substation_distance_m),
              string_agg(cadastral_ref || '=' || nearest_substation_distance_m, ', ' ORDER BY cadastral_ref)) AS detail
  FROM bess
UNION ALL
SELECT 'BESS pilot view: exclusion overlap flagged on DEBY-0917-0004 only',
       count(*) FILTER (WHERE exclusion_overlap_m2 > 0) = 1
       AND bool_or(cadastral_ref = 'DEBY-0917-0004' AND exclusion_overlap_m2 > 0),
       coalesce(string_agg(cadastral_ref || ' ' || exclusion_overlap_m2 || ' m2', ', ')
                FILTER (WHERE exclusion_overlap_m2 > 0), 'none')
  FROM bess
UNION ALL
SELECT 'Peatland pilot view: overlap and eco-points on DEBY-0917-0001 and -0003 only',
       array_agg(cadastral_ref ORDER BY cadastral_ref) FILTER (WHERE peatland_overlap_m2 > 0)
           = ARRAY['DEBY-0917-0001', 'DEBY-0917-0003']
       AND bool_and(eco_points_estimate = round(peatland_overlap_m2 * 8, 2))
           FILTER (WHERE peatland_overlap_m2 > 0),
       coalesce(string_agg(format('%s: %s m2 -> %s eco-points', cadastral_ref, peatland_overlap_m2, eco_points_estimate),
                           ', ' ORDER BY cadastral_ref) FILTER (WHERE peatland_overlap_m2 > 0), 'none')
  FROM peat
UNION ALL
SELECT 'Controlled promotion: bad fixture rows rejected with explicit reasons',
       count(*) = 4 AND bool_and(reject_reason IS NOT NULL),
       string_agg(entity || ' ' || coalesce(source_feature_id, '?') || ': ' || reject_reason, '; '
                  ORDER BY entity, source_feature_id)
  FROM rejected
UNION ALL
SELECT 'Country scoping: NL fixtures promoted and screened independently of DE',
       (SELECT count(*) FROM iris_core.parcel WHERE country_code = 'NL') = 2
       AND (SELECT count(*) FROM iris_core.v_peatland_screening
             WHERE country_code = 'NL' AND peatland_overlap_m2 > 0) = 2,
       (SELECT string_agg(country_code || '=' || n, ', ' ORDER BY country_code)
          FROM (SELECT country_code, count(*) AS n FROM iris_core.parcel GROUP BY country_code) x) || ' parcels'
UNION ALL
SELECT 'Source runs: all promoted, none left loading/failed',
       not_promoted = 0 AND total > 0,
       format('%s runs, %s not promoted', total, not_promoted)
  FROM runs;

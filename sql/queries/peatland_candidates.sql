-- Peatland pilot: parcels in DE-BY with peat overlap and the indicative eco-point estimate.
-- psql "postgresql://iris:iris@localhost:55432/iris" -f sql/queries/peatland_candidates.sql

SELECT country_code,
       region_code,
       cadastral_ref,
       area_m2,
       peatland_overlap_m2,
       peatland_overlap_ratio,
       eco_points_estimate,
       restriction_overlap_m2,
       source_id,
       source_date,
       ST_AsGeoJSON(ST_Transform(geom, 4326), 7) AS geom_geojson_4326,
       uncertainty_note
  FROM iris_core.v_peatland_screening
 WHERE country_code = 'DE'
   AND region_code = 'DE-BY'
   AND peatland_overlap_m2 > 0
 ORDER BY eco_points_estimate DESC, cadastral_ref;

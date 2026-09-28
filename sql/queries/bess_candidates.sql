-- BESS pilot: parcels in DE-BY ranked by grid proximity, excluding hard constraints.
-- psql "postgresql://iris:iris@localhost:55432/iris" -f sql/queries/bess_candidates.sql

SELECT country_code,
       region_code,
       cadastral_ref,
       area_m2,
       nearest_substation_name,
       nearest_substation_voltage_kv,
       nearest_substation_distance_m,
       restriction_overlap_m2,
       constraint_layers,
       source_id,
       source_date,
       evidence_source_date
  FROM iris_core.v_bess_screening
 WHERE country_code = 'DE'
   AND region_code = 'DE-BY'
   AND exclusion_overlap_m2 = 0
   AND nearest_substation_distance_m IS NOT NULL
 ORDER BY nearest_substation_distance_m, cadastral_ref;

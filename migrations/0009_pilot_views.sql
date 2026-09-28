-- 0009: pilot query surface.
--
-- One row per parcel per vertical, built only from the latest derivation run of each
-- (country_code, region_code).
--   * Overlap areas are 0 when screening found no overlap: a measured fact.
--   * nearest_substation_* is NULL when no substation lies within the search radius; it is never
--     filled with a guess.

CREATE FUNCTION iris_core.prospecting_disclaimer()
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT 'Preliminary prospecting material. Figures, eco-point estimates and site suitability are '
        || 'indicative and based on available source data and commercial screening assumptions. '
        || 'The 8 eco-points/m2 factor is the current commercial baseline, not certified compensation. '
        || 'Ownership, planning, grid capacity, environmental eligibility and transferability remain '
        || 'subject to project-specific verification. No permit, reservation or construction readiness '
        || 'is represented.'
$$;

CREATE VIEW iris_core.v_latest_derive_run AS
SELECT DISTINCT ON (country_code, region_code)
       country_code, region_code, source_run_id, source_id, source_date
  FROM iris_core.source_run
 WHERE run_kind = 'derive' AND status = 'promoted'
 ORDER BY country_code, region_code, source_date DESC, source_run_id DESC;

CREATE VIEW iris_core.v_bess_screening AS
WITH ev AS (
    SELECT e.*
      FROM iris_core.evidence e
      JOIN iris_core.v_latest_derive_run r
        ON r.country_code = e.country_code AND r.source_run_id = e.source_run_id
     WHERE e.vertical = 'bess'
)
SELECT p.country_code,
       p.region_code,
       p.parcel_id,
       p.cadastral_ref,
       round(p.area_m2::numeric, 2)                         AS area_m2,
       prox.substation_id                                   AS nearest_substation_id,
       s.name                                               AS nearest_substation_name,
       s.voltage_kv                                         AS nearest_substation_voltage_kv,
       prox.metric_value                                    AS nearest_substation_distance_m,
       COALESCE(scr.exclusion_overlap_m2, 0)                AS exclusion_overlap_m2,
       COALESCE(scr.restriction_overlap_m2, 0)              AS restriction_overlap_m2,
       scr.constraint_layers,
       p.source_id,
       p.source_date,
       prox.source_date                                     AS evidence_source_date,
       p.geom,
       iris_core.prospecting_disclaimer()                   AS uncertainty_note
  FROM iris_core.parcel p
  LEFT JOIN ev prox
         ON prox.country_code = p.country_code AND prox.parcel_id = p.parcel_id
        AND prox.evidence_type = 'substation_proximity'
  LEFT JOIN iris_core.substation s
         ON s.country_code = prox.country_code AND s.substation_id = prox.substation_id
  LEFT JOIN LATERAL (
        SELECT sum(x.metric_value) FILTER (WHERE x.assumptions ->> 'layer_category' = 'exclusion')   AS exclusion_overlap_m2,
               sum(x.metric_value) FILTER (WHERE x.assumptions ->> 'layer_category' = 'restriction') AS restriction_overlap_m2,
               array_agg(DISTINCT x.assumptions ->> 'layer_code' ORDER BY x.assumptions ->> 'layer_code') AS constraint_layers
          FROM ev x
         WHERE x.country_code = p.country_code AND x.parcel_id = p.parcel_id
           AND x.evidence_type = 'screening_overlap'
         HAVING count(*) > 0
  ) scr ON true;

CREATE VIEW iris_core.v_peatland_screening AS
WITH ev AS (
    SELECT e.*
      FROM iris_core.evidence e
      JOIN iris_core.v_latest_derive_run r
        ON r.country_code = e.country_code AND r.source_run_id = e.source_run_id
     WHERE e.vertical = 'peatland'
)
SELECT p.country_code,
       p.region_code,
       p.parcel_id,
       p.cadastral_ref,
       round(p.area_m2::numeric, 2)                                            AS area_m2,
       COALESCE(agg.peatland_overlap_m2, 0)                                    AS peatland_overlap_m2,
       round(COALESCE(agg.peatland_overlap_m2, 0) / p.area_m2::numeric, 4)     AS peatland_overlap_ratio,
       COALESCE(agg.eco_points_estimate, 0)                                    AS eco_points_estimate,
       agg.peatland_ids,
       COALESCE(agg.restriction_overlap_m2, 0)                                 AS restriction_overlap_m2,
       COALESCE(agg.exclusion_overlap_m2, 0)                                   AS exclusion_overlap_m2,
       p.source_id,
       p.source_date,
       p.geom,
       iris_core.prospecting_disclaimer()                                      AS uncertainty_note
  FROM iris_core.parcel p
  LEFT JOIN LATERAL (
        SELECT sum(x.metric_value) FILTER (WHERE x.evidence_type = 'peatland_overlap')   AS peatland_overlap_m2,
               sum(x.metric_value) FILTER (WHERE x.evidence_type = 'eco_point_estimate') AS eco_points_estimate,
               array_agg(DISTINCT x.peatland_id) FILTER (WHERE x.peatland_id IS NOT NULL) AS peatland_ids,
               sum(x.metric_value) FILTER (WHERE x.evidence_type = 'screening_overlap'
                                             AND x.assumptions ->> 'layer_category' = 'restriction') AS restriction_overlap_m2,
               sum(x.metric_value) FILTER (WHERE x.evidence_type = 'screening_overlap'
                                             AND x.assumptions ->> 'layer_category' = 'exclusion')   AS exclusion_overlap_m2
          FROM ev x
         WHERE x.country_code = p.country_code AND x.parcel_id = p.parcel_id
  ) agg ON true;

COMMENT ON VIEW iris_core.v_bess_screening IS
    'BESS pilot query surface: nearest substation and constraint overlaps per parcel (latest derive run).';
COMMENT ON VIEW iris_core.v_peatland_screening IS
    'Peatland pilot query surface: peat overlap and indicative eco-points per parcel (latest derive run).';

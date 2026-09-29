-- Live (non-materialised) BESS screening: nearest substations of at least 110 kV per parcel,
-- straight from the core tables. Shows the index-assisted KNN pattern that
-- iris_core.derive_evidence() uses; handy for ad-hoc what-if thresholds.
-- psql "postgresql://iris:iris@localhost:55432/iris" -f sql/screening/live_nearest_substation.sql

SELECT p.cadastral_ref,
       n.name                 AS substation,
       n.voltage_kv,
       round(n.distance_m::numeric, 1) AS distance_m
  FROM iris_core.parcel p
  CROSS JOIN LATERAL (
        SELECT s.name, s.voltage_kv, ST_Distance(p.geom, s.geom) AS distance_m
          FROM iris_core.substation s
         WHERE s.country_code = p.country_code
           AND s.voltage_kv >= 110                      -- unknown voltage (NULL) is excluded, not assumed
           AND ST_DWithin(s.geom, p.geom, 20000)
         ORDER BY s.geom <-> p.geom
         LIMIT 3
  ) n
 WHERE p.country_code = 'DE' AND p.region_code = 'DE-BY'
 ORDER BY p.cadastral_ref, n.distance_m;

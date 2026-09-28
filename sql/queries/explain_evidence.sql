-- Explainability: every number behind one parcel's screening result, with unit, method,
-- assumptions and source lineage.
-- psql "postgresql://iris:iris@localhost:55432/iris" -f sql/queries/explain_evidence.sql

SELECT e.vertical,
       e.evidence_type,
       e.metric_value,
       e.metric_unit,
       coalesce(s.name, sl.layer_code, 'peatland ' || pl.source_feature_id) AS related_feature,
       e.method,
       e.assumptions,
       e.source_id   AS evidence_source_id,
       e.source_date AS evidence_source_date,
       coalesce(s.source_id, pl.source_id, sl.source_id)       AS input_source_id,
       coalesce(s.source_date, pl.source_date, sl.source_date) AS input_source_date
  FROM iris_core.evidence e
  JOIN iris_core.parcel p ON p.country_code = e.country_code AND p.parcel_id = e.parcel_id
  LEFT JOIN iris_core.substation s
         ON s.country_code = e.country_code AND s.substation_id = e.substation_id
  LEFT JOIN iris_core.peatland pl
         ON pl.country_code = e.country_code AND pl.peatland_id = e.peatland_id
  LEFT JOIN iris_core.screening_layer sl
         ON sl.country_code = e.country_code AND sl.screening_layer_id = e.screening_layer_id
 WHERE p.country_code = 'DE' AND p.cadastral_ref = 'DEBY-0917-0003'
 ORDER BY e.vertical, e.evidence_type;

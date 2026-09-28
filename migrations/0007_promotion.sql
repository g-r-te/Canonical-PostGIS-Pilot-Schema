-- 0007: controlled promotion from iris_staging into iris_core.
--
-- Flow per source run:   pending --validate--> validated | rejected --promote--> promoted
--
--   * Row-level problems (bad geometry, wrong SRID, unknown region, missing key attribute, bad
--     vocabulary) become 'rejected' rows with an explicit reject_reason. They never abort the batch
--     and are never silently repaired or defaulted.
--   * Validated rows are transformed to EPSG:3035 and upserted on
--     (country_code, source_id, source_feature_id), so re-running a promotion is idempotent.
--   * The core CHECK/FK constraints remain the final authority: if something slips past the
--     staging checks, the whole promotion transaction fails loudly instead of storing bad data.

-- Returns NULL when the geometry satisfies the storage contract, else a human-readable reason.
CREATE FUNCTION iris_staging.geom_reject_reason(g geometry, expected_srid integer, family text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN g IS NULL                THEN 'geom missing'
        WHEN ST_SRID(g) = 0           THEN 'geom SRID undeclared (0)'
        WHEN ST_SRID(g) <> expected_srid
            THEN format('geom SRID %s does not match source_run.source_srid %s', ST_SRID(g), expected_srid)
        WHEN ST_IsEmpty(g)            THEN 'geom empty'
        WHEN ST_NDims(g) <> 2         THEN 'geom has Z/M dimensions; 2D required'
        WHEN family = 'polygon' AND GeometryType(g) NOT IN ('POLYGON', 'MULTIPOLYGON')
            THEN format('geom type %s, expected POLYGON or MULTIPOLYGON', GeometryType(g))
        WHEN family = 'point' AND GeometryType(g) <> 'POINT'
            THEN format('geom type %s, expected POINT', GeometryType(g))
        WHEN NOT ST_IsValid(g)        THEN 'geom invalid: ' || ST_IsValidReason(g)
        WHEN NOT ST_IsValid(ST_Transform(g, 3035))
            THEN 'geom invalid after transform to EPSG:3035'
    END
$$;

-- Generic row-level validation shared by all entities. Marks pending rows validated/rejected.
CREATE FUNCTION iris_staging.validate_pending(
    p_table            regclass,
    p_country_code     text,
    p_source_run_id    bigint,
    p_geom_family      text,
    p_region_required  boolean,
    p_required_props   text[] DEFAULT '{}',
    p_numeric_props    text[] DEFAULT '{}',
    p_unique_props     text[] DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_srid integer;
BEGIN
    SELECT source_srid INTO STRICT v_srid
      FROM iris_core.source_run
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id;

    EXECUTE format($sql$
        WITH pending AS (
            SELECT s.staging_id, s.geom, s.region_code, s.source_feature_id, s.properties,
                   count(*) OVER (PARTITION BY s.source_feature_id) AS feature_dups
              FROM %1$s s
             WHERE s.country_code = $1 AND s.source_run_id = $2 AND s.load_status = 'pending'
        ),
        checked AS (
            SELECT p.staging_id, COALESCE(
                CASE WHEN nullif(btrim(p.source_feature_id), '') IS NULL
                     THEN 'source_feature_id missing' END,
                CASE WHEN p.feature_dups > 1
                     THEN 'source_feature_id duplicated within source run' END,
                (SELECT 'required property missing: ' || k
                   FROM unnest($6::text[]) AS k
                  WHERE nullif(btrim(p.properties ->> k), '') IS NULL
                  LIMIT 1),
                (SELECT 'property is not a non-negative number: ' || k
                   FROM unnest($7::text[]) AS k
                  WHERE p.properties ->> k IS NOT NULL
                    AND (p.properties ->> k) !~ '^[0-9]+(\.[0-9]+)?$'
                  LIMIT 1),
                (SELECT 'property duplicated within source run: ' || k
                   FROM unnest($8::text[]) AS k
                  WHERE (SELECT count(*) FROM pending q
                          WHERE q.properties ->> k = p.properties ->> k) > 1
                  LIMIT 1),
                CASE WHEN $5 AND nullif(btrim(p.region_code), '') IS NULL
                     THEN 'region_code missing' END,
                CASE WHEN p.region_code IS NOT NULL AND NOT EXISTS (
                         SELECT 1 FROM iris_core.region r
                          WHERE r.country_code = $1 AND r.region_code = p.region_code)
                     THEN format('region_code %%s is not a known region of %%s', p.region_code, $1) END,
                iris_staging.geom_reject_reason(p.geom, $3, $4)
            ) AS reason
              FROM pending p
        )
        UPDATE %1$s s
           SET load_status   = CASE WHEN c.reason IS NULL THEN 'validated' ELSE 'rejected' END,
               reject_reason = c.reason
          FROM checked c
         WHERE s.staging_id = c.staging_id
    $sql$, p_table)
    USING p_country_code, p_source_run_id, v_srid, p_geom_family, p_region_required,
          p_required_props, p_numeric_props, p_unique_props;
END
$$;

-- Marks validated rows promoted, records counts on source_run, returns (promoted, rejected).
CREATE FUNCTION iris_staging.finish_promotion(p_table regclass, p_country_code text, p_source_run_id bigint)
RETURNS TABLE (promoted integer, rejected integer)
LANGUAGE plpgsql AS $$
DECLARE
    v_staged   integer;
    v_promoted integer;
    v_rejected integer;
BEGIN
    EXECUTE format(
        'UPDATE %s SET load_status = ''promoted'', promoted_at = now()
          WHERE country_code = $1 AND source_run_id = $2 AND load_status = ''validated''', p_table)
    USING p_country_code, p_source_run_id;

    EXECUTE format(
        'SELECT count(*)::int,
                count(*) FILTER (WHERE load_status = ''promoted'')::int,
                count(*) FILTER (WHERE load_status = ''rejected'')::int
           FROM %s WHERE country_code = $1 AND source_run_id = $2', p_table)
    INTO v_staged, v_promoted, v_rejected
    USING p_country_code, p_source_run_id;

    UPDATE iris_core.source_run
       SET status = 'promoted', rows_staged = v_staged, rows_promoted = v_promoted,
           rows_rejected = v_rejected, updated_at = now()
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id;

    RETURN QUERY SELECT v_promoted, v_rejected;
END
$$;

CREATE FUNCTION iris_staging.get_run(p_country_code text, p_source_run_id bigint)
RETURNS iris_core.source_run
LANGUAGE plpgsql AS $$
DECLARE
    r iris_core.source_run;
BEGIN
    SELECT * INTO r FROM iris_core.source_run
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id
       FOR UPDATE;                                   -- serialise concurrent promotions of one run
    IF NOT FOUND THEN
        RAISE EXCEPTION 'source_run (%, %) does not exist', p_country_code, p_source_run_id;
    END IF;
    IF r.run_kind <> 'ingest' THEN
        RAISE EXCEPTION 'source_run (%, %) is a % run; only ingest runs can be promoted',
            p_country_code, p_source_run_id, r.run_kind;
    END IF;
    RETURN r;
END
$$;

------------------------------------------------------------------------------------------------
-- Entity-specific promotion
------------------------------------------------------------------------------------------------
CREATE FUNCTION iris_staging.promote_parcel(p_country_code text, p_source_run_id bigint)
RETURNS TABLE (promoted integer, rejected integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    r iris_core.source_run := iris_staging.get_run(p_country_code, p_source_run_id);
BEGIN
    PERFORM iris_staging.validate_pending('iris_staging.parcel', p_country_code, p_source_run_id,
        'polygon', true, ARRAY['cadastral_ref'], '{}', ARRAY['cadastral_ref']);

    INSERT INTO iris_core.parcel (country_code, region_code, cadastral_ref, land_use, geom,
                                  source_run_id, source_id, source_date, source_feature_id)
    SELECT s.country_code, s.region_code, btrim(s.properties ->> 'cadastral_ref'),
           s.properties ->> 'land_use', ST_Multi(ST_Transform(s.geom, 3035)),
           r.source_run_id, r.source_id, r.source_date, s.source_feature_id
      FROM iris_staging.parcel s
     WHERE s.country_code = p_country_code AND s.source_run_id = p_source_run_id
       AND s.load_status = 'validated'
    ON CONFLICT (country_code, source_id, source_feature_id) DO UPDATE
       SET region_code = EXCLUDED.region_code, cadastral_ref = EXCLUDED.cadastral_ref,
           land_use = EXCLUDED.land_use, geom = EXCLUDED.geom,
           source_run_id = EXCLUDED.source_run_id, source_date = EXCLUDED.source_date,
           updated_at = now();

    RETURN QUERY SELECT * FROM iris_staging.finish_promotion('iris_staging.parcel', p_country_code, p_source_run_id);
END
$$;

CREATE FUNCTION iris_staging.promote_substation(p_country_code text, p_source_run_id bigint)
RETURNS TABLE (promoted integer, rejected integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    r iris_core.source_run := iris_staging.get_run(p_country_code, p_source_run_id);
BEGIN
    PERFORM iris_staging.validate_pending('iris_staging.substation', p_country_code, p_source_run_id,
        'point', true, '{}', ARRAY['voltage_kv']);

    UPDATE iris_staging.substation
       SET load_status = 'rejected', reject_reason = 'voltage_kv must be > 0'
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id
       AND load_status = 'validated'
       AND CASE WHEN (properties ->> 'voltage_kv') ~ '^[0-9]+(\.[0-9]+)?$'
                THEN (properties ->> 'voltage_kv')::numeric <= 0
                ELSE false END;

    INSERT INTO iris_core.substation (country_code, region_code, name, operator, voltage_kv, geom,
                                      source_run_id, source_id, source_date, source_feature_id)
    SELECT s.country_code, s.region_code, s.properties ->> 'name', s.properties ->> 'operator',
           (s.properties ->> 'voltage_kv')::numeric, ST_Transform(s.geom, 3035),
           r.source_run_id, r.source_id, r.source_date, s.source_feature_id
      FROM iris_staging.substation s
     WHERE s.country_code = p_country_code AND s.source_run_id = p_source_run_id
       AND s.load_status = 'validated'
    ON CONFLICT (country_code, source_id, source_feature_id) DO UPDATE
       SET region_code = EXCLUDED.region_code, name = EXCLUDED.name, operator = EXCLUDED.operator,
           voltage_kv = EXCLUDED.voltage_kv, geom = EXCLUDED.geom,
           source_run_id = EXCLUDED.source_run_id, source_date = EXCLUDED.source_date,
           updated_at = now();

    RETURN QUERY SELECT * FROM iris_staging.finish_promotion('iris_staging.substation', p_country_code, p_source_run_id);
END
$$;

CREATE FUNCTION iris_staging.promote_peatland(p_country_code text, p_source_run_id bigint)
RETURNS TABLE (promoted integer, rejected integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    r iris_core.source_run := iris_staging.get_run(p_country_code, p_source_run_id);
BEGIN
    PERFORM iris_staging.validate_pending('iris_staging.peatland', p_country_code, p_source_run_id,
        'polygon', true);

    UPDATE iris_staging.peatland
       SET load_status = 'rejected',
           reject_reason = format('peat_class %s not in (bog, fen, transition)', properties ->> 'peat_class')
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id
       AND load_status = 'validated'
       AND properties ->> 'peat_class' IS NOT NULL
       AND properties ->> 'peat_class' NOT IN ('bog', 'fen', 'transition');

    INSERT INTO iris_core.peatland (country_code, region_code, peat_class, geom,
                                    source_run_id, source_id, source_date, source_feature_id)
    SELECT s.country_code, s.region_code, s.properties ->> 'peat_class',
           ST_Multi(ST_Transform(s.geom, 3035)),
           r.source_run_id, r.source_id, r.source_date, s.source_feature_id
      FROM iris_staging.peatland s
     WHERE s.country_code = p_country_code AND s.source_run_id = p_source_run_id
       AND s.load_status = 'validated'
    ON CONFLICT (country_code, source_id, source_feature_id) DO UPDATE
       SET region_code = EXCLUDED.region_code, peat_class = EXCLUDED.peat_class, geom = EXCLUDED.geom,
           source_run_id = EXCLUDED.source_run_id, source_date = EXCLUDED.source_date,
           updated_at = now();

    RETURN QUERY SELECT * FROM iris_staging.finish_promotion('iris_staging.peatland', p_country_code, p_source_run_id);
END
$$;

CREATE FUNCTION iris_staging.promote_screening_layer(p_country_code text, p_source_run_id bigint)
RETURNS TABLE (promoted integer, rejected integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    r iris_core.source_run := iris_staging.get_run(p_country_code, p_source_run_id);
BEGIN
    -- region_code optional: national layers (e.g. Natura 2000) have no single region.
    PERFORM iris_staging.validate_pending('iris_staging.screening_layer', p_country_code, p_source_run_id,
        'polygon', false, ARRAY['layer_code', 'layer_category']);

    UPDATE iris_staging.screening_layer
       SET load_status = 'rejected',
           reject_reason = CASE
               WHEN (properties ->> 'layer_code') !~ '^[a-z0-9][a-z0-9_]*$'
                   THEN 'layer_code must match ^[a-z0-9][a-z0-9_]*$'
               WHEN properties ->> 'layer_category' NOT IN ('exclusion', 'restriction', 'information')
                   THEN 'layer_category not in (exclusion, restriction, information)'
               ELSE 'applies_to must be a non-empty JSON array drawn from (bess, peatland)'
           END
     WHERE country_code = p_country_code AND source_run_id = p_source_run_id
       AND load_status = 'validated'
       AND (   (properties ->> 'layer_code') !~ '^[a-z0-9][a-z0-9_]*$'
            OR properties ->> 'layer_category' NOT IN ('exclusion', 'restriction', 'information')
            OR CASE WHEN jsonb_typeof(properties -> 'applies_to') = 'array'
                    THEN jsonb_array_length(properties -> 'applies_to') = 0
                         OR NOT (properties -> 'applies_to') <@ '["bess", "peatland"]'::jsonb
                    ELSE true END);

    INSERT INTO iris_core.screening_layer (country_code, region_code, layer_code, layer_category,
                                           applies_to, feature_name, geom,
                                           source_run_id, source_id, source_date, source_feature_id)
    SELECT s.country_code, s.region_code, s.properties ->> 'layer_code', s.properties ->> 'layer_category',
           ARRAY(SELECT DISTINCT jsonb_array_elements_text(s.properties -> 'applies_to') ORDER BY 1),
           s.properties ->> 'feature_name', ST_Multi(ST_Transform(s.geom, 3035)),
           r.source_run_id, r.source_id, r.source_date, s.source_feature_id
      FROM iris_staging.screening_layer s
     WHERE s.country_code = p_country_code AND s.source_run_id = p_source_run_id
       AND s.load_status = 'validated'
    ON CONFLICT (country_code, source_id, source_feature_id) DO UPDATE
       SET region_code = EXCLUDED.region_code, layer_code = EXCLUDED.layer_code,
           layer_category = EXCLUDED.layer_category, applies_to = EXCLUDED.applies_to,
           feature_name = EXCLUDED.feature_name, geom = EXCLUDED.geom,
           source_run_id = EXCLUDED.source_run_id, source_date = EXCLUDED.source_date,
           updated_at = now();

    RETURN QUERY SELECT * FROM iris_staging.finish_promotion('iris_staging.screening_layer', p_country_code, p_source_run_id);
END
$$;

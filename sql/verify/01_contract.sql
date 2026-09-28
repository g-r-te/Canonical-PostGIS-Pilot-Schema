-- Acceptance criteria 2 & 3: canonical names exist, country_code is never nullable,
-- geometry columns follow the storage contract.
-- Output contract for every verify file: (check_name text, ok boolean, detail text).

WITH entity(table_name) AS (
    VALUES ('parcel'), ('substation'), ('peatland'), ('screening_layer'), ('evidence')
),
canonical(column_name) AS (
    VALUES ('geom'), ('country_code'), ('region_code'), ('source_id'), ('source_date'), ('created_at')
),
missing_canonical AS (
    SELECT e.table_name || '.' || c.column_name AS col
      FROM entity e CROSS JOIN canonical c
     WHERE NOT EXISTS (
           SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = 'iris_core' AND ic.table_name = e.table_name
              AND ic.column_name = c.column_name)
),
source_run_missing AS (
    SELECT c.column_name AS col
      FROM canonical c
     WHERE c.column_name <> 'geom'
       AND NOT EXISTS (
           SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = 'iris_core' AND ic.table_name = 'source_run'
              AND ic.column_name = c.column_name)
),
geometry_named AS (
    SELECT table_name || '.' || column_name AS col
      FROM information_schema.columns
     WHERE table_schema = 'iris_core' AND column_name = 'geometry'
),
base_tables AS (
    SELECT table_schema, table_name
      FROM information_schema.tables
     WHERE table_schema IN ('iris_core', 'iris_staging') AND table_type = 'BASE TABLE'
),
country_code_problems AS (
    SELECT t.table_schema || '.' || t.table_name
           || CASE WHEN c.column_name IS NULL THEN ' (no country_code)' ELSE ' (nullable)' END AS col
      FROM base_tables t
      LEFT JOIN information_schema.columns c
             ON c.table_schema = t.table_schema AND c.table_name = t.table_name
            AND c.column_name = 'country_code'
     WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
),
expected_geom(f_table_name, type) AS (
    VALUES ('parcel', 'MULTIPOLYGON'), ('substation', 'POINT'), ('peatland', 'MULTIPOLYGON'),
           ('screening_layer', 'MULTIPOLYGON'), ('evidence', 'GEOMETRY')
),
geom_problems AS (
    SELECT e.f_table_name || ' expected ' || e.type || '/3035, found '
           || coalesce(g.type || '/' || g.srid, 'no geom column') AS col
      FROM expected_geom e
      LEFT JOIN geometry_columns g
             ON g.f_table_schema = 'iris_core' AND g.f_table_name = e.f_table_name
            AND g.f_geometry_column = 'geom'
     WHERE g.srid IS DISTINCT FROM 3035 OR g.type IS DISTINCT FROM e.type
),
missing_gist AS (
    SELECT e.f_table_name AS col
      FROM expected_geom e
     WHERE NOT EXISTS (
           SELECT 1 FROM pg_indexes i
            WHERE i.schemaname = 'iris_core' AND i.tablename = e.f_table_name
              AND i.indexdef LIKE '%USING gist (geom)%')
)
SELECT 'canonical columns on every core entity' AS check_name,
       count(*) = 0 AS ok,
       coalesce('missing: ' || string_agg(col, ', '),
                '5 entities x (geom, country_code, region_code, source_id, source_date, created_at)') AS detail
  FROM missing_canonical
UNION ALL
SELECT 'source_run carries canonical metadata names', count(*) = 0,
       coalesce('missing: ' || string_agg(col, ', '), 'country_code, region_code, source_id, source_date, created_at')
  FROM source_run_missing
UNION ALL
SELECT 'no column named "geometry" in iris_core', count(*) = 0,
       coalesce(string_agg(col, ', '), 'none found')
  FROM geometry_named
UNION ALL
SELECT 'country_code NOT NULL on every iris_core/iris_staging table', count(*) = 0,
       coalesce(string_agg(col, ', '),
                (SELECT count(*) || ' tables checked' FROM base_tables))
  FROM country_code_problems
UNION ALL
SELECT 'geom typmod: expected type and SRID 3035', count(*) = 0,
       coalesce(string_agg(col, '; '), 'parcel/peatland/screening_layer MULTIPOLYGON, substation POINT, evidence GEOMETRY')
  FROM geom_problems
UNION ALL
SELECT 'GiST index on every geom column', count(*) = 0,
       coalesce('missing: ' || string_agg(col, ', '), 'present on all 5 spatial tables')
  FROM missing_gist;

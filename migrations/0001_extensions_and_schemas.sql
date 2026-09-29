-- 0001: extensions, schemas and shared domains.
--
-- iris_staging : raw, permissive landing tables (any SRID, any geometry type, jsonb attributes).
-- iris_core    : canonical, strictly typed, country-scoped business entities.
-- iris_meta    : migration bookkeeping (created by the migration runner, not here).

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA iris_core;
CREATE SCHEMA iris_staging;

COMMENT ON SCHEMA iris_core IS
    'Canonical IRIS pilot entities. Storage CRS EPSG:3035 (ETRS89-LAEA), column geom, non-null country_code.';
COMMENT ON SCHEMA iris_staging IS
    'Raw landing zone. Rows are validated and promoted into iris_core by iris_staging.promote_* functions.';

-- ISO 3166-1 alpha-2 (upper case). NOT NULL is declared on each column, not on the domain,
-- so that nullability is visible in information_schema and outer joins behave normally.
CREATE DOMAIN iris_core.iso_country_code AS text
    CHECK (VALUE ~ '^[A-Z]{2}$');

-- ISO 3166-2 subdivision code, e.g. DE-BY.
CREATE DOMAIN iris_core.iso_region_code AS text
    CHECK (VALUE ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$');

-- Stable, lower-case, URL-safe identifier of a data source (e.g. de-by-cadastre).
CREATE DOMAIN iris_core.source_identifier AS text
    CHECK (VALUE ~ '^[a-z0-9][a-z0-9._-]{1,99}$');

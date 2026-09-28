-- 0003: source metadata.
--
-- A source_run is one ingested vintage of one source for one country (or one derivation run).
-- It is the explicit contract for provenance, CRS, source date, completeness and positional
-- uncertainty. Every canonical entity references exactly one source_run.

CREATE TABLE iris_core.source_run (
    source_run_id          bigint GENERATED ALWAYS AS IDENTITY,
    country_code           iris_core.iso_country_code  NOT NULL REFERENCES iris_core.country (country_code),
    region_code            iris_core.iso_region_code,          -- NULL = national extent
    source_id              iris_core.source_identifier NOT NULL,
    source_date            date        NOT NULL,               -- vintage / "as of" date of the data
    run_kind               text        NOT NULL DEFAULT 'ingest'
                           CHECK (run_kind IN ('ingest', 'derive')),
    source_srid            integer     NOT NULL REFERENCES public.spatial_ref_sys (srid),
    source_uri             text,
    license                text,
    completeness           text        NOT NULL DEFAULT 'unknown'
                           CHECK (completeness IN ('complete', 'partial', 'unknown')),
    positional_accuracy_m  numeric     CHECK (positional_accuracy_m > 0),  -- NULL = unknown, never guessed
    status                 text        NOT NULL DEFAULT 'loading'
                           CHECK (status IN ('loading', 'promoted', 'failed')),
    rows_staged            integer     CHECK (rows_staged >= 0),
    rows_promoted          integer     CHECK (rows_promoted >= 0),
    rows_rejected          integer     CHECK (rows_rejected >= 0),
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (country_code, source_run_id),
    -- One run per source vintage per country: re-loading the same vintage is a re-run, not a new run.
    CONSTRAINT source_run_vintage_uq UNIQUE (country_code, source_id, source_date),
    -- FK target that lets entities carry source_id/source_date denormalised yet provably consistent.
    CONSTRAINT source_run_lineage_uq UNIQUE (country_code, source_run_id, source_id, source_date),
    CONSTRAINT source_run_region_fk FOREIGN KEY (country_code, region_code)
        REFERENCES iris_core.region (country_code, region_code),
    CONSTRAINT source_run_source_date_sane CHECK (source_date BETWEEN DATE '1900-01-01' AND DATE '2100-01-01')
);

COMMENT ON TABLE  iris_core.source_run IS 'One ingested (or derived) vintage of a source for one country.';
COMMENT ON COLUMN iris_core.source_run.source_srid IS 'CRS the source was delivered in. Core storage is always EPSG:3035.';
COMMENT ON COLUMN iris_core.source_run.positional_accuracy_m IS 'Declared positional uncertainty in metres; NULL when the source does not state it.';

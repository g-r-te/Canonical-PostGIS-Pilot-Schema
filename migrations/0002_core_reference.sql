-- 0002: reference data for country-aware keys.
--
-- country and region are the anchor of every country-scoped foreign key. region uses a
-- composite primary key (country_code, region_code) so that any FK to it proves the region
-- belongs to the same country as the referencing row.

CREATE TABLE iris_core.country (
    country_code  iris_core.iso_country_code NOT NULL PRIMARY KEY,
    name          text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE iris_core.region (
    country_code  iris_core.iso_country_code NOT NULL REFERENCES iris_core.country (country_code),
    region_code   iris_core.iso_region_code  NOT NULL,
    name          text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (country_code, region_code),
    CONSTRAINT region_code_prefix_matches_country
        CHECK (left(region_code, 3) = country_code || '-')
);

COMMENT ON TABLE iris_core.region IS 'ISO 3166-2 subdivisions enabled for IRIS. PK is country-scoped.';

-- Controlled vocabulary for the pilot. Adding a country is a data change, not a schema change.
INSERT INTO iris_core.country (country_code, name) VALUES
    ('DE', 'Germany'),
    ('NL', 'Netherlands');

INSERT INTO iris_core.region (country_code, region_code, name) VALUES
    ('DE', 'DE-BY', 'Bayern'),
    ('DE', 'DE-BW', 'Baden-Württemberg'),
    ('NL', 'NL-FR', 'Fryslân'),
    ('NL', 'NL-GR', 'Groningen');

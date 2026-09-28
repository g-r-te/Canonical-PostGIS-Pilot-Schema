"""Key and constraint design: the database itself must refuse bad data.

Every test runs in a rolled-back transaction; each expected failure is isolated in a savepoint
(``conn.transaction()``) so later statements in the same test still run.
"""

from __future__ import annotations

from typing import Any

import psycopg
import pytest
from psycopg import errors

pytestmark = pytest.mark.db

# 100 m x 100 m square in EPSG:3035 inside Bavaria.
SQUARE_3035 = (
    "ST_Multi(ST_GeomFromText("
    "'POLYGON((4430000 2820000, 4430100 2820000, 4430100 2820100, 4430000 2820100, "
    "4430000 2820000))', 3035))"
)


def insert_parcel(
    conn: psycopg.Connection,
    run: tuple[int, str, Any],
    *,
    country_code: str | None = "DE",
    region_code: str = "DE-BY",
    cadastral_ref: str = "T-0001",
    feature_id: str = "t-1",
    geom_sql: str = SQUARE_3035,
) -> int:
    run_id, source_id, source_date = run
    row = conn.execute(
        "INSERT INTO iris_core.parcel (country_code, region_code, cadastral_ref, geom,"
        " source_run_id, source_id, source_date, source_feature_id)"
        f" VALUES (%s, %s, %s, {geom_sql}, %s, %s, %s, %s) RETURNING parcel_id",
        (country_code, region_code, cadastral_ref, run_id, source_id, source_date, feature_id),
    ).fetchone()
    assert row is not None
    return row[0]


def expect(conn: psycopg.Connection, exc: type[Exception], fn, *args, **kwargs) -> None:
    with pytest.raises(exc), conn.transaction():
        fn(*args, **kwargs)


# --------------------------------------------------------------------------- country_code


@pytest.mark.parametrize(
    "table",
    ["source_run", "parcel", "substation", "peatland", "screening_layer", "evidence", "region"],
)
def test_country_code_is_declared_not_null(conn: psycopg.Connection, table: str) -> None:
    (nullable,) = conn.execute(
        "SELECT is_nullable FROM information_schema.columns"
        " WHERE table_schema = 'iris_core' AND table_name = %s AND column_name = 'country_code'",
        (table,),
    ).fetchone()
    assert nullable == "NO"


def test_null_country_code_is_rejected_on_insert(conn, make_run) -> None:
    run = make_run()
    expect(conn, errors.NotNullViolation, insert_parcel, conn, run, country_code=None)


def test_null_country_code_is_rejected_in_staging(conn, make_run) -> None:
    run_id, _, _ = make_run()
    expect(
        conn, errors.NotNullViolation, conn.execute,
        "INSERT INTO iris_staging.parcel (country_code, source_run_id) VALUES (NULL, %s)",
        (run_id,),
    )  # fmt: skip


@pytest.mark.parametrize("bad", ["de", "DEU", "D1", ""])
def test_country_code_must_be_iso_alpha2(conn, bad: str) -> None:
    expect(
        conn, errors.CheckViolation, conn.execute,
        "INSERT INTO iris_core.country (country_code, name) VALUES (%s, 'x')", (bad,),
    )  # fmt: skip


def test_unknown_country_is_rejected(conn) -> None:
    expect(
        conn, errors.ForeignKeyViolation, conn.execute,
        "INSERT INTO iris_core.source_run (country_code, source_id, source_date, source_srid)"
        " VALUES ('FR', 'x-src', '2026-01-01', 4326)",
    )  # fmt: skip


# --------------------------------------------------------------------------- region scoping


def test_region_must_belong_to_the_rows_country(conn, make_run) -> None:
    run = make_run(country_code="DE")
    # NL-FR exists, but not for DE: the composite FK (country_code, region_code) refuses it.
    expect(conn, errors.ForeignKeyViolation, insert_parcel, conn, run, region_code="NL-FR")


def test_region_code_prefix_must_match_country(conn) -> None:
    expect(
        conn, errors.CheckViolation, conn.execute,
        "INSERT INTO iris_core.region (country_code, region_code, name) VALUES ('DE', 'NL-XX', 'x')",
    )  # fmt: skip


# --------------------------------------------------------------------------- keys


def test_cadastral_ref_is_unique_per_country_not_globally(conn, make_run) -> None:
    de_run = make_run(country_code="DE")
    nl_run = make_run(country_code="NL")
    insert_parcel(conn, de_run, cadastral_ref="SAME-REF", feature_id="a")
    expect(
        conn, errors.UniqueViolation, insert_parcel, conn, de_run,
        cadastral_ref="SAME-REF", feature_id="b",
    )  # fmt: skip
    # Same reference in another country is a different parcel.
    insert_parcel(conn, nl_run, country_code="NL", region_code="NL-FR",
                  cadastral_ref="SAME-REF", feature_id="a")  # fmt: skip


def test_source_feature_id_is_unique_per_country_and_source(conn, make_run) -> None:
    run = make_run()
    insert_parcel(conn, run, cadastral_ref="R1", feature_id="dup")
    expect(
        conn, errors.UniqueViolation, insert_parcel, conn, run, cadastral_ref="R2", feature_id="dup"
    )


def test_primary_keys_are_country_scoped(conn) -> None:
    rows = conn.execute(
        """
        SELECT c.conrelid::regclass::text, array_agg(a.attname ORDER BY k.ord)
          FROM pg_constraint c
          CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
         WHERE c.contype = 'p' AND c.connamespace = 'iris_core'::regnamespace
         GROUP BY c.conrelid
        """
    ).fetchall()
    pks = dict(rows)
    for table in ("parcel", "substation", "peatland", "screening_layer", "evidence", "source_run"):
        assert pks[f"iris_core.{table}"][0] == "country_code", table


def test_entity_cannot_reference_a_source_run_of_another_country(conn, make_run) -> None:
    nl_run = make_run(country_code="NL")
    expect(conn, errors.ForeignKeyViolation, insert_parcel, conn, nl_run, country_code="DE")


def test_source_id_and_date_must_match_the_referenced_run(conn, make_run) -> None:
    run_id, source_id, source_date = make_run()
    expect(
        conn, errors.ForeignKeyViolation, insert_parcel, conn, (run_id, "other-source", source_date)
    )
    expect(conn, errors.ForeignKeyViolation, insert_parcel, conn, (run_id, source_id, "2020-01-01"))


def test_source_run_vintage_is_unique(conn, make_run) -> None:
    _, source_id, source_date = make_run()
    expect(
        conn, errors.UniqueViolation, conn.execute,
        "INSERT INTO iris_core.source_run (country_code, source_id, source_date, source_srid)"
        " VALUES ('DE', %s, %s, 4326)", (source_id, source_date),
    )  # fmt: skip


def test_source_run_srid_must_be_a_known_crs(conn) -> None:
    expect(
        conn, errors.ForeignKeyViolation, conn.execute,
        "INSERT INTO iris_core.source_run (country_code, source_id, source_date, source_srid)"
        " VALUES ('DE', 'bad-crs', '2026-01-01', 999999)",
    )  # fmt: skip


# --------------------------------------------------------------------------- geometry contract


@pytest.mark.parametrize(
    ("geom_sql", "exc"),
    [
        # wrong SRID (typmod)
        ("ST_Multi(ST_GeomFromText('POLYGON((11 48, 11.1 48, 11.1 48.1, 11 48))', 4326))",
         errors.InvalidParameterValue),
        # wrong type (typmod): a point is not a MultiPolygon
        ("ST_GeomFromText('POINT(4430000 2820000)', 3035)", errors.InvalidParameterValue),
        # invalid (self-intersecting bow-tie)
        ("ST_Multi(ST_GeomFromText('POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))', 3035))",
         errors.CheckViolation),
        # empty
        ("ST_GeomFromText('MULTIPOLYGON EMPTY', 3035)", errors.CheckViolation),
        # missing
        ("NULL", errors.NotNullViolation),
    ],
    ids=["wrong-srid", "wrong-type", "invalid", "empty", "null"],
)  # fmt: skip
def test_parcel_geometry_contract(conn, make_run, geom_sql: str, exc: type[Exception]) -> None:
    run = make_run()
    expect(conn, exc, insert_parcel, conn, run, geom_sql=geom_sql)


def test_area_is_generated_in_square_metres(conn, make_run) -> None:
    parcel_id = insert_parcel(conn, make_run())
    (area,) = conn.execute(
        "SELECT area_m2 FROM iris_core.parcel WHERE country_code = 'DE' AND parcel_id = %s",
        (parcel_id,),
    ).fetchone()
    assert area == pytest.approx(10_000.0)


# --------------------------------------------------------------------------- evidence contract


def _evidence_sql(**overrides: str) -> str:
    cols = {
        "vertical": "'bess'",
        "evidence_type": "'substation_proximity'",
        "substation_id": "(SELECT max(substation_id) FROM iris_core.substation WHERE country_code = 'DE')",
        "peatland_id": "NULL",
        "metric_value": "10",
        "metric_unit": "'m'",
        "assumptions": "'{}'::jsonb",
    }
    cols.update(overrides)
    return f"""
        INSERT INTO iris_core.evidence (country_code, region_code, parcel_id, vertical, evidence_type,
               substation_id, peatland_id, metric_value, metric_unit, method, assumptions,
               source_run_id, source_id, source_date)
        SELECT p.country_code, p.region_code, p.parcel_id, {cols["vertical"]}, {cols["evidence_type"]},
               {cols["substation_id"]}, {cols["peatland_id"]}, {cols["metric_value"]},
               {cols["metric_unit"]}, 'test', {cols["assumptions"]},
               r.source_run_id, r.source_id, r.source_date
          FROM iris_core.parcel p, iris_core.source_run r
         WHERE p.country_code = 'DE' AND p.cadastral_ref = 'DEBY-0917-0001'
           AND r.country_code = 'DE' AND r.run_kind = 'derive'
    """


def test_valid_evidence_row_is_accepted(conn) -> None:
    conn.execute(_evidence_sql(metric_value="999"))


@pytest.mark.parametrize(
    "overrides",
    [
        {"metric_unit": "'m2'"},  # proximity must be in metres
        {"vertical": "'peatland'"},  # proximity belongs to the BESS vertical
        {"substation_id": "NULL", "peatland_id":
            "(SELECT min(peatland_id) FROM iris_core.peatland WHERE country_code = 'DE')"},
        {"evidence_type": "'eco_point_estimate'", "vertical": "'peatland'", "substation_id": "NULL",
         "peatland_id": "(SELECT min(peatland_id) FROM iris_core.peatland WHERE country_code = 'DE')",
         "metric_unit": "'eco_points'"},  # eco-points without the stated factor
        {"metric_value": "-1"},
    ],
    ids=["wrong-unit", "wrong-vertical", "wrong-related-feature", "eco-points-no-factor", "negative"],
)  # fmt: skip
def test_evidence_type_contract(conn, overrides: dict[str, str]) -> None:
    expect(conn, errors.CheckViolation, conn.execute, _evidence_sql(**overrides))


def test_evidence_requires_exactly_one_related_feature(conn) -> None:
    expect(
        conn, errors.CheckViolation, conn.execute,
        _evidence_sql(peatland_id="(SELECT min(peatland_id) FROM iris_core.peatland"
                                  " WHERE country_code = 'DE')"),
    )  # fmt: skip


def test_evidence_region_must_be_the_parcels_region(conn) -> None:
    sql_text = _evidence_sql().replace("p.region_code, p.parcel_id", "'DE-BW', p.parcel_id")
    expect(conn, errors.ForeignKeyViolation, conn.execute, sql_text)


def test_evidence_cannot_link_features_across_countries(conn) -> None:
    nl_substation = (
        "(SELECT min(substation_id) FROM iris_core.substation WHERE country_code = 'NL')"
    )
    expect(
        conn, errors.ForeignKeyViolation, conn.execute, _evidence_sql(substation_id=nl_substation)
    )

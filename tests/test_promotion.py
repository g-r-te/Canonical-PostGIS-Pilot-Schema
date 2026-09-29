"""Controlled promotion, seed determinism and derived evidence."""

from __future__ import annotations

import json

import psycopg
import pytest

from iris_schema import config, seed

pytestmark = pytest.mark.db

DE_MANIFEST = config.project_root() / "fixtures" / "de" / "manifest.json"


def _rejections(conn: psycopg.Connection) -> dict[str, str]:
    rows = conn.execute(
        """
        SELECT source_feature_id, reject_reason FROM iris_staging.parcel WHERE load_status = 'rejected'
        UNION ALL SELECT source_feature_id, reject_reason FROM iris_staging.substation WHERE load_status = 'rejected'
        UNION ALL SELECT source_feature_id, reject_reason FROM iris_staging.peatland WHERE load_status = 'rejected'
        UNION ALL SELECT source_feature_id, reject_reason FROM iris_staging.screening_layer WHERE load_status = 'rejected'
        """  # noqa: E501
    ).fetchall()
    return dict(rows)


def test_bad_fixture_rows_are_rejected_with_explicit_reasons(conn: psycopg.Connection) -> None:
    rejected = _rejections(conn)
    assert set(rejected) == {"DEBY-SYN-P005", "DEBY-SYN-P006", "DEBY-SYN-M003", "DE-SYN-UW-004"}
    assert rejected["DEBY-SYN-P005"].startswith("geom invalid: Self-intersection")
    assert rejected["DEBY-SYN-P006"] == "region_code missing"
    assert "peat_class swamp" in rejected["DEBY-SYN-M003"]
    assert rejected["DE-SYN-UW-004"] == "geom missing"


def test_rejected_rows_never_reach_core(conn: psycopg.Connection) -> None:
    (n,) = conn.execute(
        "SELECT count(*) FROM iris_core.parcel"
        " WHERE source_feature_id IN ('DEBY-SYN-P005', 'DEBY-SYN-P006')"
    ).fetchone()
    assert n == 0


def test_unknown_attributes_stay_null(conn: psycopg.Connection) -> None:
    (voltage,) = conn.execute(
        "SELECT voltage_kv FROM iris_core.substation"
        " WHERE country_code = 'DE' AND source_feature_id = 'DE-SYN-UW-003'"
    ).fetchone()
    assert voltage is None  # blank in the source: not guessed, not defaulted


def test_source_run_records_counts_and_contract(conn: psycopg.Connection) -> None:
    rows = conn.execute(
        "SELECT source_id, source_srid, rows_staged, rows_promoted, rows_rejected, status"
        "  FROM iris_core.source_run WHERE country_code = 'DE' AND run_kind = 'ingest'"
        " ORDER BY source_id"
    ).fetchall()
    assert rows == [
        ("de-by-cadastre-synthetic", 4326, 6, 4, 2, "promoted"),
        ("de-by-peatland-synthetic", 4326, 3, 2, 1, "promoted"),
        ("de-grid-substations-synthetic", 25832, 4, 3, 1, "promoted"),
        ("de-screening-synthetic", 4326, 2, 2, 0, "promoted"),
    ]


def test_reseeding_is_idempotent(conn: psycopg.Connection) -> None:
    def snapshot() -> list[tuple]:
        return conn.execute(
            "SELECT 'parcel', country_code, parcel_id, source_feature_id FROM iris_core.parcel"
            " UNION ALL SELECT 'evidence', country_code, count(*), evidence_type"
            "  FROM iris_core.evidence GROUP BY country_code, evidence_type"
            " UNION ALL SELECT 'run', country_code, source_run_id, source_id FROM iris_core.source_run"
            " ORDER BY 1, 2, 3, 4"
        ).fetchall()

    before = snapshot()
    report = seed.seed(conn, DE_MANIFEST)
    assert snapshot() == before  # same ids, same rows, same evidence
    assert [r.promoted for r in report.sources] == [4, 2, 3, 2]


def test_promotion_rejects_srid_that_contradicts_the_source_run(conn, make_run) -> None:
    run_id, _, _ = make_run(srid=25832)
    conn.execute(
        "INSERT INTO iris_staging.parcel (country_code, source_run_id, source_feature_id, region_code,"
        " properties, geom) VALUES ('DE', %s, 'f1', 'DE-BY', %s,"
        " ST_GeomFromText('POLYGON((11 48, 11.1 48, 11.1 48.1, 11 48))', 4326))",
        (run_id, json.dumps({"cadastral_ref": "SRID-TEST"})),
    )
    promoted, rejected = conn.execute(
        "SELECT * FROM iris_staging.promote_parcel('DE', %s)", (run_id,)
    ).fetchone()
    assert (promoted, rejected) == (0, 1)
    (reason,) = conn.execute(
        "SELECT reject_reason FROM iris_staging.parcel WHERE source_run_id = %s", (run_id,)
    ).fetchone()
    assert reason == "geom SRID 4326 does not match source_run.source_srid 25832"


@pytest.mark.parametrize(
    ("props", "region", "wkt", "expected"),
    [
        ({"cadastral_ref": "X"}, "DE-XX", "POLYGON((0 0,1 0,1 1,0 0))", "region_code DE-XX is not a known region of DE"),
        ({}, "DE-BY", "POLYGON((0 0,1 0,1 1,0 0))", "required property missing: cadastral_ref"),
        ({"cadastral_ref": "X"}, "DE-BY", "LINESTRING(0 0,1 1)", "geom type LINESTRING, expected POLYGON or MULTIPOLYGON"),
        ({"cadastral_ref": "X"}, "DE-BY", "POLYGON Z((0 0 1,1 0 1,1 1 1,0 0 1))", "geom has Z/M dimensions; 2D required"),
    ],
    ids=["unknown-region", "missing-key", "wrong-type", "3d"],
)  # fmt: skip
def test_promotion_row_level_rejections(conn, make_run, props, region, wkt, expected) -> None:
    run_id, _, _ = make_run(srid=3035)
    conn.execute(
        "INSERT INTO iris_staging.parcel (country_code, source_run_id, source_feature_id, region_code,"
        " properties, geom) VALUES ('DE', %s, 'f1', %s, %s, ST_GeomFromText(%s, 3035))",
        (run_id, region, json.dumps(props), wkt),
    )
    conn.execute("SELECT * FROM iris_staging.promote_parcel('DE', %s)", (run_id,))
    (status, reason) = conn.execute(
        "SELECT load_status, reject_reason FROM iris_staging.parcel WHERE source_run_id = %s",
        (run_id,),
    ).fetchone()
    assert (status, reason) == ("rejected", expected)


def test_duplicate_feature_ids_within_a_run_are_rejected_not_merged(conn, make_run) -> None:
    run_id, _, _ = make_run(srid=3035)
    for ref in ("A", "B"):
        conn.execute(
            "INSERT INTO iris_staging.parcel (country_code, source_run_id, source_feature_id,"
            " region_code, properties, geom) VALUES ('DE', %s, 'same', 'DE-BY', %s,"
            " ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 0))', 3035))",
            (run_id, json.dumps({"cadastral_ref": ref})),
        )
    assert conn.execute(
        "SELECT * FROM iris_staging.promote_parcel('DE', %s)", (run_id,)
    ).fetchone() == (0, 2)


def test_derived_evidence_matches_fixture_geometry(conn: psycopg.Connection) -> None:
    counts = dict(
        conn.execute(
            "SELECT evidence_type, count(*) FROM iris_core.evidence"
            " WHERE country_code = 'DE' GROUP BY evidence_type"
        ).fetchall()
    )
    assert counts == {
        "substation_proximity": 4,
        "peatland_overlap": 2,
        "eco_point_estimate": 2,
        "screening_overlap": 3,
    }

    nearest = dict(
        conn.execute(
            "SELECT p.cadastral_ref, s.source_feature_id"
            "  FROM iris_core.evidence e"
            "  JOIN iris_core.parcel p USING (country_code, parcel_id)"
            "  JOIN iris_core.substation s USING (country_code, substation_id)"
            " WHERE e.country_code = 'DE' AND e.evidence_type = 'substation_proximity'"
        ).fetchall()
    )
    assert set(nearest.values()) == {"DE-SYN-UW-001"}


def test_peatland_overlap_and_eco_points_are_consistent(conn: psycopg.Connection) -> None:
    rows = conn.execute(
        """
        SELECT o.metric_value, ST_Area(ST_Intersection(p.geom, pl.geom)), e.metric_value, e.assumptions
          FROM iris_core.evidence o
          JOIN iris_core.evidence e
            ON e.country_code = o.country_code AND e.source_run_id = o.source_run_id
           AND e.parcel_id = o.parcel_id AND e.peatland_id = o.peatland_id
           AND e.evidence_type = 'eco_point_estimate'
          JOIN iris_core.parcel p ON p.country_code = o.country_code AND p.parcel_id = o.parcel_id
          JOIN iris_core.peatland pl ON pl.country_code = o.country_code AND pl.peatland_id = o.peatland_id
         WHERE o.country_code = 'DE' AND o.evidence_type = 'peatland_overlap'
        """
    ).fetchall()
    assert len(rows) == 2
    for overlap_m2, recomputed_m2, eco_points, assumptions in rows:
        assert float(overlap_m2) == pytest.approx(recomputed_m2, abs=0.01)
        assert assumptions["eco_points_per_m2"] == 8
        assert "not certified" in assumptions["basis"]
        assert eco_points == round(overlap_m2 * 8, 2)


def test_multi_vertical_screening_layer_yields_one_fact_per_vertical(conn) -> None:
    rows = conn.execute(
        "SELECT p.cadastral_ref, e.vertical FROM iris_core.evidence e"
        "  JOIN iris_core.parcel p USING (country_code, parcel_id)"
        "  JOIN iris_core.screening_layer sl USING (country_code, screening_layer_id)"
        " WHERE e.country_code = 'DE' AND sl.layer_code = 'flood_zone_hq100' ORDER BY 2"
    ).fetchall()
    assert rows == [("DEBY-0917-0003", "bess"), ("DEBY-0917-0003", "peatland")]


def test_rederiving_replaces_rather_than_duplicates(conn: psycopg.Connection) -> None:
    (before,) = conn.execute("SELECT count(*) FROM iris_core.evidence").fetchone()
    conn.execute("SELECT * FROM iris_core.derive_evidence('DE', 'DE-BY', '2026-07-01')")
    (after,) = conn.execute("SELECT count(*) FROM iris_core.evidence").fetchone()
    assert before == after


def test_pilot_views_carry_the_uncertainty_wording(conn: psycopg.Connection) -> None:
    (note,) = conn.execute(
        "SELECT DISTINCT uncertainty_note FROM iris_core.v_peatland_screening"
    ).fetchone()
    assert note.startswith("Preliminary prospecting material.")
    assert "not certified compensation" in note

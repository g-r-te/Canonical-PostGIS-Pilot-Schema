"""Spatial design: CRS round trip, measurement units and index usage."""

from __future__ import annotations

import json

import psycopg
import pytest

from iris_schema import config, verify

pytestmark = pytest.mark.db

POLYGON_4326 = {
    "type": "Polygon",
    "coordinates": [[[11.5, 48.1], [11.51, 48.1], [11.51, 48.107], [11.5, 48.107], [11.5, 48.1]]],
}


def test_geojson_round_trip_through_core_storage(conn: psycopg.Connection, make_run) -> None:
    run_id, source_id, source_date = make_run()
    conn.execute(
        "INSERT INTO iris_core.parcel (country_code, region_code, cadastral_ref, geom,"
        " source_run_id, source_id, source_date, source_feature_id)"
        " VALUES ('DE', 'DE-BY', 'RT-1',"
        "  ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326), 3035)),"
        "  %s, %s, %s, 'rt-1')",
        (json.dumps(POLYGON_4326), run_id, source_id, source_date),
    )
    srid, geojson, area_m2, geodesic_m2 = conn.execute(
        "SELECT ST_SRID(geom), ST_AsGeoJSON(ST_Transform(geom, 4326), 12), area_m2,"
        "       ST_Area(ST_GeomFromGeoJSON(%s)::geography)"
        "  FROM iris_core.parcel WHERE country_code = 'DE' AND cadastral_ref = 'RT-1'",
        (json.dumps(POLYGON_4326),),
    ).fetchone()

    assert srid == 3035
    returned = json.loads(geojson)
    assert returned["type"] == "MultiPolygon"
    ring_in = POLYGON_4326["coordinates"][0]
    ring_out = returned["coordinates"][0][0]
    assert len(ring_in) == len(ring_out)
    for (x0, y0), (x1, y1) in zip(ring_in, ring_out, strict=True):
        assert x1 == pytest.approx(x0, abs=1e-8)
        assert y1 == pytest.approx(y0, abs=1e-8)
    # EPSG:3035 is equal-area: planar area equals the ellipsoidal area.
    assert area_m2 == pytest.approx(geodesic_m2, rel=1e-5)


def test_fixture_crs_are_normalised_to_3035(conn: psycopg.Connection) -> None:
    rows = conn.execute(
        "SELECT r.source_srid, ST_SRID(s.geom)"
        "  FROM iris_core.substation s JOIN iris_core.source_run r USING (country_code, source_run_id)"
        " UNION "
        "SELECT r.source_srid, ST_SRID(p.geom)"
        "  FROM iris_core.parcel p JOIN iris_core.source_run r USING (country_code, source_run_id)"
    ).fetchall()
    source_srids = {src for src, _ in rows}
    stored_srids = {stored for _, stored in rows}
    assert {4326, 25832, 28992} <= source_srids  # three delivery CRSs in the fixtures
    assert stored_srids == {3035}  # one storage CRS


def test_all_verification_checks_pass(conn: psycopg.Connection) -> None:
    results = verify.run_all(conn, config.verify_dir())
    failures = [f"{r.check_name}: {r.detail}" for r in results if not r.ok]
    assert not failures, "\n".join(failures)
    assert len(results) >= 15


def test_index_usage_is_demonstrated_for_each_pilot_query_shape(conn: psycopg.Connection) -> None:
    results = verify.run_file(conn, config.verify_dir() / "03_index_usage.sql")
    assert results and all(r.ok for r in results), [(r.check_name, r.detail) for r in results]
    covered = " ".join(r.detail for r in results)
    for index in ("substation_geom_gist", "peatland_geom_gist", "screening_layer_geom_gist"):
        assert index in covered
    # KNN: the distance ordering itself is served by the GiST index (no sort of all candidates).
    (knn,) = [r for r in results if r.check_name.startswith("BESS: nearest substation")]
    assert knn.ok and '"Order By"' in knn.detail

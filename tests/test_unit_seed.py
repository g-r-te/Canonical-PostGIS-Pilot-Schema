"""Fixture manifest and file adapters (no database required)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from iris_schema import config
from iris_schema.seed import ManifestError, SourceSpec, load_manifest, read_features


def _manifest(tmp_path: Path, **overrides: object) -> Path:
    doc = {
        "country_code": "DE",
        "sources": [
            {
                "source_id": "x",
                "entity": "parcel",
                "file": "p.geojson",
                "format": "geojson",
                "srid": 4326,
                "source_date": "2026-01-01",
            }
        ],
    }
    doc.update(overrides)
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def test_committed_manifests_load() -> None:
    manifests = config.default_manifests()
    assert {p.parent.name for p in manifests} == {"de", "nl"}
    for path in manifests:
        manifest = load_manifest(path)
        assert manifest.sources
        for spec in manifest.sources:
            assert (manifest.base_dir / spec.file).is_file(), spec.file
            assert list(read_features(spec, manifest.base_dir)), f"{spec.file} is empty"


@pytest.mark.parametrize("country_code", [None, "de", "DEU", "D"])
def test_manifest_requires_iso_country_code(tmp_path: Path, country_code: object) -> None:
    with pytest.raises(ManifestError, match="country_code"):
        load_manifest(_manifest(tmp_path, country_code=country_code))


@pytest.mark.parametrize(
    ("patch", "message"),
    [
        ({"entity": "building"}, "unknown entity"),
        ({"format": "shapefile"}, "unknown format"),
        ({"srid": 0}, "srid must be a positive integer"),
        ({"source_date": "30/06/2026"}, "invalid ISO date"),
        ({"completeness": "mostly"}, "completeness"),
    ],
)
def test_manifest_rejects_invalid_source(tmp_path: Path, patch: dict, message: str) -> None:
    source = {
        "source_id": "x",
        "entity": "parcel",
        "file": "p.geojson",
        "format": "geojson",
        "srid": 4326,
        "source_date": "2026-01-01",
        **patch,
    }
    with pytest.raises(ManifestError, match=message):
        load_manifest(_manifest(tmp_path, sources=[source]))


def test_manifest_requires_srid_to_be_declared(tmp_path: Path) -> None:
    source = {"source_id": "x", "entity": "parcel", "file": "f", "format": "geojson",
              "source_date": "2026-01-01"}  # fmt: skip
    with pytest.raises(ManifestError, match="srid"):
        load_manifest(_manifest(tmp_path, sources=[source]))


def _spec(fmt: str, file: str, **kw: object) -> SourceSpec:
    from datetime import date

    return SourceSpec(
        source_id="x", entity="substation", file=file, format=fmt,
        source_date=date(2026, 1, 1), srid=25832, **kw,
    )  # fmt: skip


def test_csv_points_empty_cells_are_omitted_not_defaulted(tmp_path: Path) -> None:
    (tmp_path / "s.csv").write_text(
        "source_feature_id,voltage_kv,x,y,region_code\nA,,1.5,2.5,DE-BY\nB,110,,2.5,\n",
        encoding="utf-8",
    )
    a, b = read_features(_spec("csv_points", "s.csv"), tmp_path)
    assert a.source_feature_id == "A" and a.region_code == "DE-BY"
    assert "voltage_kv" not in a.properties  # unknown stays unknown
    assert a.geojson == {"type": "Point", "coordinates": [1.5, 2.5]}
    assert b.geojson is None and b.region_code is None  # missing coordinate -> no geometry


def test_csv_points_non_numeric_coordinate_is_a_file_error(tmp_path: Path) -> None:
    (tmp_path / "s.csv").write_text("source_feature_id,x,y\nA,abc,1\n", encoding="utf-8")
    with pytest.raises(ManifestError, match="s.csv:2"):
        list(read_features(_spec("csv_points", "s.csv"), tmp_path))


def test_geojson_feature_id_and_region_are_lifted_out_of_properties(tmp_path: Path) -> None:
    doc = {
        "type": "FeatureCollection",
        "features": [
            {"type": "Feature", "id": 7, "properties": {"region_code": "DE-BY", "a": 1},
             "geometry": None},
        ],
    }  # fmt: skip
    (tmp_path / "f.geojson").write_text(json.dumps(doc), encoding="utf-8")
    (feature,) = read_features(_spec("geojson", "f.geojson"), tmp_path)
    assert feature.source_feature_id == "7"
    assert feature.region_code == "DE-BY"
    assert feature.properties == {"a": 1}
    assert feature.geojson is None


def test_csv_wkt_reads_geometry_text(tmp_path: Path) -> None:
    (tmp_path / "p.csv").write_text(
        'source_feature_id,wkt\nP1,"POLYGON((0 0, 1 0, 1 1, 0 0))"\n', encoding="utf-8"
    )
    (feature,) = read_features(_spec("csv_wkt", "p.csv"), tmp_path)
    assert feature.wkt == "POLYGON((0 0, 1 0, 1 1, 0 0))"
    assert feature.properties == {}

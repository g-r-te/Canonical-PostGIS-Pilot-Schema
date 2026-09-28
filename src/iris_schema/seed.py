"""Fixture loader: files -> iris_staging -> (promotion) -> iris_core -> derived evidence.

The loader is a thin, country-aware adapter. It never interprets or repairs geometry: it declares
the source CRS, lands every feature in staging as delivered, and lets the SQL promotion functions
decide (and record) what is accepted. Re-running the seed is idempotent.
"""

from __future__ import annotations

import csv
import json
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
from psycopg import sql
from psycopg.types.json import Jsonb

# entity -> (staging table, promotion function). Whitelist: never build identifiers from input.
ENTITIES: dict[str, tuple[str, str]] = {
    "parcel": ("parcel", "promote_parcel"),
    "substation": ("substation", "promote_substation"),
    "peatland": ("peatland", "promote_peatland"),
    "screening_layer": ("screening_layer", "promote_screening_layer"),
}
FORMATS = frozenset({"geojson", "csv_points", "csv_wkt"})
COMPLETENESS = frozenset({"complete", "partial", "unknown"})


class ManifestError(ValueError):
    """The fixture manifest or a fixture file is structurally invalid."""


@dataclass(frozen=True)
class SourceSpec:
    source_id: str
    entity: str
    file: str
    format: str
    source_date: date
    srid: int
    region_code: str | None = None
    source_uri: str | None = None
    license: str | None = None
    completeness: str = "unknown"
    positional_accuracy_m: float | None = None
    x_field: str = "x"
    y_field: str = "y"
    wkt_field: str = "wkt"


@dataclass(frozen=True)
class DeriveSpec:
    region_code: str
    as_of_date: date
    max_substation_distance_m: float = 20000
    eco_points_per_m2: float = 8


@dataclass(frozen=True)
class Manifest:
    country_code: str
    base_dir: Path
    sources: tuple[SourceSpec, ...]
    derive: DeriveSpec | None


@dataclass(frozen=True)
class StagedFeature:
    source_feature_id: str | None
    region_code: str | None
    properties: dict[str, Any]
    geojson: dict[str, Any] | None = None  # geometry as delivered, coordinates in the source CRS
    wkt: str | None = None


@dataclass
class SourceResult:
    source_id: str
    entity: str
    source_run_id: int
    staged: int
    promoted: int
    rejected: int
    rejections: list[tuple[str | None, str]] = field(default_factory=list)


@dataclass
class SeedReport:
    country_code: str
    sources: list[SourceResult]
    evidence: dict[str, int]


def _parse_date(value: Any, where: str) -> date:
    try:
        return date.fromisoformat(str(value))
    except ValueError as exc:
        raise ManifestError(f"{where}: invalid ISO date {value!r}") from exc


def load_manifest(path: Path) -> Manifest:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read manifest {path}: {exc}") from exc

    country_code = raw.get("country_code")
    if not isinstance(country_code, str) or len(country_code) != 2 or not country_code.isupper():
        raise ManifestError("manifest.country_code must be an ISO 3166-1 alpha-2 code, e.g. 'DE'")

    sources: list[SourceSpec] = []
    for i, s in enumerate(raw.get("sources", [])):
        where = f"sources[{i}]"
        missing = {"source_id", "entity", "file", "format", "source_date", "srid"} - s.keys()
        if missing:
            raise ManifestError(f"{where}: missing keys {sorted(missing)}")
        if s["entity"] not in ENTITIES:
            raise ManifestError(f"{where}: unknown entity {s['entity']!r}")
        if s["format"] not in FORMATS:
            raise ManifestError(f"{where}: unknown format {s['format']!r}")
        if s.get("completeness", "unknown") not in COMPLETENESS:
            raise ManifestError(f"{where}: completeness must be one of {sorted(COMPLETENESS)}")
        if not isinstance(s["srid"], int) or s["srid"] <= 0:
            raise ManifestError(f"{where}: srid must be a positive integer (the source CRS)")
        sources.append(
            SourceSpec(
                source_id=s["source_id"],
                entity=s["entity"],
                file=s["file"],
                format=s["format"],
                source_date=_parse_date(s["source_date"], where),
                srid=s["srid"],
                region_code=s.get("region_code"),
                source_uri=s.get("source_uri"),
                license=s.get("license"),
                completeness=s.get("completeness", "unknown"),
                positional_accuracy_m=s.get("positional_accuracy_m"),
                x_field=s.get("x_field", "x"),
                y_field=s.get("y_field", "y"),
                wkt_field=s.get("wkt_field", "wkt"),
            )
        )
    if not sources:
        raise ManifestError("manifest declares no sources")

    derive = None
    if d := raw.get("derive"):
        derive = DeriveSpec(
            region_code=d["region_code"],
            as_of_date=_parse_date(d["as_of_date"], "derive"),
            max_substation_distance_m=d.get("max_substation_distance_m", 20000),
            eco_points_per_m2=d.get("eco_points_per_m2", 8),
        )
    return Manifest(country_code, path.parent, tuple(sources), derive)


def read_features(spec: SourceSpec, base_dir: Path) -> Iterator[StagedFeature]:
    path = base_dir / spec.file
    if spec.format == "geojson":
        yield from _read_geojson(path)
    elif spec.format == "csv_points":
        yield from _read_csv_points(path, spec.x_field, spec.y_field)
    else:
        yield from _read_csv_wkt(path, spec.wkt_field)


def _read_geojson(path: Path) -> Iterator[StagedFeature]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if doc.get("type") != "FeatureCollection":
        raise ManifestError(f"{path.name}: expected a GeoJSON FeatureCollection")
    for feature in doc.get("features", []):
        props = dict(feature.get("properties") or {})
        feature_id = feature.get("id", props.pop("source_feature_id", None))
        yield StagedFeature(
            source_feature_id=None if feature_id is None else str(feature_id),
            region_code=props.pop("region_code", None),
            properties=props,
            geojson=feature.get("geometry"),
        )


def _read_csv_rows(path: Path) -> Iterator[tuple[int, dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as fh:
        for line_no, row in enumerate(csv.DictReader(fh), start=2):
            # Empty cells mean "not stated by the source" and are omitted, never defaulted.
            yield line_no, {k: v.strip() for k, v in row.items() if v is not None and v.strip()}


def _read_csv_points(path: Path, x_field: str, y_field: str) -> Iterator[StagedFeature]:
    for line_no, props in _read_csv_rows(path):
        x, y = props.pop(x_field, None), props.pop(y_field, None)
        geojson = None
        if x is not None and y is not None:
            try:
                geojson = {"type": "Point", "coordinates": [float(x), float(y)]}
            except ValueError as exc:
                raise ManifestError(f"{path.name}:{line_no}: non-numeric coordinate") from exc
        yield StagedFeature(
            source_feature_id=props.pop("source_feature_id", None),
            region_code=props.pop("region_code", None),
            properties=props,
            geojson=geojson,
        )


def _read_csv_wkt(path: Path, wkt_field: str) -> Iterator[StagedFeature]:
    for _, props in _read_csv_rows(path):
        wkt = props.pop(wkt_field, None)
        yield StagedFeature(
            source_feature_id=props.pop("source_feature_id", None),
            region_code=props.pop("region_code", None),
            properties=props,
            wkt=wkt,
        )


def _upsert_source_run(conn: psycopg.Connection, country_code: str, spec: SourceSpec) -> int:
    row = conn.execute(
        """
        INSERT INTO iris_core.source_run
               (country_code, region_code, source_id, source_date, run_kind, source_srid,
                source_uri, license, completeness, positional_accuracy_m, status)
        VALUES (%s, %s, %s, %s, 'ingest', %s, %s, %s, %s, %s, 'loading')
        ON CONFLICT ON CONSTRAINT source_run_vintage_uq DO UPDATE
           SET region_code = EXCLUDED.region_code, source_srid = EXCLUDED.source_srid,
               source_uri = EXCLUDED.source_uri, license = EXCLUDED.license,
               completeness = EXCLUDED.completeness,
               positional_accuracy_m = EXCLUDED.positional_accuracy_m,
               status = 'loading', updated_at = now()
        RETURNING source_run_id
        """,
        (
            country_code,
            spec.region_code,
            spec.source_id,
            spec.source_date,
            spec.srid,
            spec.source_uri,
            spec.license,
            spec.completeness,
            spec.positional_accuracy_m,
        ),
    ).fetchone()
    assert row is not None
    return row[0]


def load_source(
    conn: psycopg.Connection, country_code: str, spec: SourceSpec, base_dir: Path
) -> SourceResult:
    """Stage and promote one source vintage in a single transaction."""
    table, promote_fn = ENTITIES[spec.entity]
    staging = sql.Identifier("iris_staging", table)
    features = list(read_features(spec, base_dir))

    with conn.transaction():
        run_id = _upsert_source_run(conn, country_code, spec)
        # Re-loading a vintage replaces its staged rows (idempotent seed).
        conn.execute(
            sql.SQL("DELETE FROM {} WHERE country_code = %s AND source_run_id = %s").format(
                staging
            ),
            (country_code, run_id),
        )
        with conn.cursor() as cur:
            cur.executemany(
                sql.SQL(
                    "INSERT INTO {} (country_code, source_run_id, source_feature_id, region_code,"
                    " properties, geom)"
                    " VALUES (%s, %s, %s, %s, %s,"
                    "  ST_SetSRID(COALESCE(ST_GeomFromGeoJSON(%s::text),"
                    "                       ST_GeomFromText(%s::text)), %s::integer))"
                ).format(staging),
                [
                    (
                        country_code,
                        run_id,
                        f.source_feature_id,
                        f.region_code,
                        Jsonb(f.properties),
                        None if f.geojson is None else json.dumps(f.geojson),
                        f.wkt,
                        spec.srid,
                    )
                    for f in features
                ],
            )
        promoted, rejected = conn.execute(
            sql.SQL("SELECT promoted, rejected FROM {}(%s, %s)").format(
                sql.Identifier("iris_staging", promote_fn)
            ),
            (country_code, run_id),
        ).fetchone()  # type: ignore[misc]
        rejections = conn.execute(
            sql.SQL(
                "SELECT source_feature_id, reject_reason FROM {}"
                " WHERE country_code = %s AND source_run_id = %s AND load_status = 'rejected'"
                " ORDER BY source_feature_id NULLS FIRST, staging_id"
            ).format(staging),
            (country_code, run_id),
        ).fetchall()

    return SourceResult(
        source_id=spec.source_id,
        entity=spec.entity,
        source_run_id=run_id,
        staged=len(features),
        promoted=promoted,
        rejected=rejected,
        rejections=[(fid, reason) for fid, reason in rejections],
    )


def derive(conn: psycopg.Connection, country_code: str, spec: DeriveSpec) -> dict[str, int]:
    with conn.transaction():
        rows = conn.execute(
            "SELECT evidence_type, row_count"
            " FROM iris_core.derive_evidence(%s, %s, %s, %s::numeric, %s::numeric)",
            (
                country_code,
                spec.region_code,
                spec.as_of_date,
                spec.max_substation_distance_m,
                spec.eco_points_per_m2,
            ),
        ).fetchall()
    return dict(rows)


def seed(conn: psycopg.Connection, manifest_path: Path) -> SeedReport:
    manifest = load_manifest(manifest_path)
    results = [
        load_source(conn, manifest.country_code, spec, manifest.base_dir)
        for spec in manifest.sources
    ]
    evidence = derive(conn, manifest.country_code, manifest.derive) if manifest.derive else {}
    return SeedReport(country_code=manifest.country_code, sources=results, evidence=evidence)

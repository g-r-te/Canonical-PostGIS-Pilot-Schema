"""Shared fixtures.

Database tests run against IRIS_TEST_DATABASE_URL (default: the iris_test database created by
docker-compose). If the database is unreachable they are skipped, unless IRIS_REQUIRE_DB=1
(set in CI), in which case they fail.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Callable, Iterator
from datetime import date

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import make_conninfo

from iris_schema import config, db, migrations, seed

TEST_DATABASE_URL = os.environ.get("IRIS_TEST_DATABASE_URL", config.DEFAULT_TEST_DATABASE_URL)


def _connect_or_skip(url: str) -> psycopg.Connection:
    try:
        return db.connect(url)
    except psycopg.OperationalError as exc:
        if os.environ.get("IRIS_REQUIRE_DB") == "1":
            raise
        pytest.skip(f"PostgreSQL/PostGIS not reachable at {url}: {exc}")


@pytest.fixture(scope="session")
def db_url() -> str:
    return TEST_DATABASE_URL


@pytest.fixture(scope="session")
def built_db(db_url: str) -> Iterator[str]:
    """Rebuild the test database once per session: reset -> migrate -> seed all fixtures."""
    with _connect_or_skip(db_url) as conn:
        db.reset(conn)
        migrations.migrate(conn, config.migrations_dir())
        for manifest in config.default_manifests():
            seed.seed(conn, manifest)
    yield db_url


@pytest.fixture
def conn(built_db: str) -> Iterator[psycopg.Connection]:
    """Connection whose work is always rolled back, keeping tests independent."""
    with db.connect(built_db) as connection, connection.transaction(force_rollback=True):
        yield connection


@pytest.fixture
def make_run(conn: psycopg.Connection) -> Callable[..., tuple[int, str, date]]:
    """Insert an ingest source_run and return (source_run_id, source_id, source_date)."""

    def _make(
        country_code: str = "DE",
        srid: int = 4326,
        source_date: date = date(2026, 1, 1),
        region_code: str | None = None,
    ) -> tuple[int, str, date]:
        source_id = f"test-{uuid.uuid4().hex[:12]}"
        row = conn.execute(
            "INSERT INTO iris_core.source_run"
            " (country_code, region_code, source_id, source_date, source_srid)"
            " VALUES (%s, %s, %s, %s, %s) RETURNING source_run_id",
            (country_code, region_code, source_id, source_date, srid),
        ).fetchone()
        assert row is not None
        return row[0], source_id, source_date

    return _make


@pytest.fixture
def scratch_database(db_url: str) -> Iterator[str]:
    """A brand-new, empty database (no postgis, no schemas); dropped afterwards."""
    name = f"iris_scratch_{uuid.uuid4().hex[:10]}"
    with _connect_or_skip(db_url) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
    url = make_conninfo(db_url, dbname=name)
    try:
        yield url
    finally:
        with db.connect(db_url) as admin:
            admin.execute(
                sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(name))
            )

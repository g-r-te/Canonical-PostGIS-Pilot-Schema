"""Minimal, forward-only SQL migration runner.

Design:
  * Migrations are ``migrations/NNNN_snake_case_name.sql`` and are applied in version order.
  * Each migration runs in its own transaction together with its bookkeeping row, so a failed
    migration leaves no partial state and is simply retried on the next run.
  * A session-level advisory lock serialises concurrent runners.
  * Checksums (sha256 over LF-normalised text) detect edits to already-applied migrations;
    drift is an error, never silently ignored.
"""

from __future__ import annotations

import hashlib
import re
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import psycopg

MIGRATION_FILE_RE = re.compile(r"^(?P<version>\d{4})_(?P<name>[a-z0-9_]+)\.sql$")

# Arbitrary constant key for pg_advisory_lock; identifies "iris schema migration".
ADVISORY_LOCK_KEY = 0x1D15_0003

BOOTSTRAP_SQL = """
CREATE SCHEMA IF NOT EXISTS iris_meta;
CREATE TABLE IF NOT EXISTS iris_meta.schema_migration (
    version       integer     PRIMARY KEY,
    name          text        NOT NULL,
    checksum      text        NOT NULL,
    execution_ms  integer     NOT NULL,
    applied_at    timestamptz NOT NULL DEFAULT now()
);
"""


class MigrationError(RuntimeError):
    """Invalid migration set or drift between disk and database."""


@dataclass(frozen=True)
class Migration:
    version: int
    name: str
    path: Path
    sql: str

    @property
    def checksum(self) -> str:
        return checksum(self.sql)

    @property
    def filename(self) -> str:
        return self.path.name


@dataclass(frozen=True)
class MigrationStatus:
    version: int
    name: str
    applied_at: datetime | None


def checksum(text: str) -> str:
    normalised = text.replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()


def discover(directory: Path) -> list[Migration]:
    """Load and validate all migrations in ``directory``, ordered by version."""
    if not directory.is_dir():
        raise MigrationError(f"migrations directory not found: {directory}")

    migrations: dict[int, Migration] = {}
    for path in sorted(directory.glob("*.sql")):
        match = MIGRATION_FILE_RE.match(path.name)
        if not match:
            raise MigrationError(f"migration file name must match NNNN_name.sql: {path.name}")
        version = int(match["version"])
        if version in migrations:
            raise MigrationError(
                f"duplicate migration version {version:04d}: "
                f"{migrations[version].filename} and {path.name}"
            )
        migrations[version] = Migration(
            version=version,
            name=match["name"],
            path=path,
            sql=path.read_text(encoding="utf-8"),
        )
    if not migrations:
        raise MigrationError(f"no migrations found in {directory}")
    return [migrations[v] for v in sorted(migrations)]


def _applied(conn: psycopg.Connection) -> dict[int, tuple[str, str, datetime]]:
    rows = conn.execute(
        "SELECT version, name, checksum, applied_at FROM iris_meta.schema_migration"
    ).fetchall()
    return {v: (n, c, a) for v, n, c, a in rows}


def _check_drift(
    migrations: list[Migration], applied: dict[int, tuple[str, str, datetime]]
) -> None:
    on_disk = {m.version: m for m in migrations}
    for version, (name, db_checksum, _) in sorted(applied.items()):
        migration = on_disk.get(version)
        if migration is None:
            raise MigrationError(f"migration {version:04d}_{name} is applied but missing on disk")
        if migration.checksum != db_checksum:
            raise MigrationError(
                f"checksum mismatch for applied migration {migration.filename}; "
                "applied migrations are immutable, add a new migration instead"
            )


def migrate(conn: psycopg.Connection, directory: Path) -> list[Migration]:
    """Apply all pending migrations. Returns the migrations applied by this call."""
    if not conn.autocommit:
        raise MigrationError("migrate() requires an autocommit connection")

    migrations = discover(directory)
    conn.execute("SELECT pg_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
    try:
        with conn.transaction():
            conn.execute(BOOTSTRAP_SQL)
        applied = _applied(conn)
        _check_drift(migrations, applied)

        newly_applied: list[Migration] = []
        for migration in migrations:
            if migration.version in applied:
                continue
            started = time.perf_counter()
            with conn.transaction():
                try:
                    conn.execute(migration.sql)
                except psycopg.Error as exc:
                    raise MigrationError(f"{migration.filename} failed: {exc}") from exc
                conn.execute(
                    "INSERT INTO iris_meta.schema_migration"
                    " (version, name, checksum, execution_ms) VALUES (%s, %s, %s, %s)",
                    (
                        migration.version,
                        migration.name,
                        migration.checksum,
                        int((time.perf_counter() - started) * 1000),
                    ),
                )
            newly_applied.append(migration)
        return newly_applied
    finally:
        conn.execute("SELECT pg_advisory_unlock(%s)", (ADVISORY_LOCK_KEY,))


def status(conn: psycopg.Connection, directory: Path) -> list[MigrationStatus]:
    """Applied/pending state of every migration on disk."""
    migrations = discover(directory)
    exists = conn.execute("SELECT to_regclass('iris_meta.schema_migration') IS NOT NULL").fetchone()
    applied = _applied(conn) if exists and exists[0] else {}
    _check_drift(migrations, applied)
    return [
        MigrationStatus(m.version, m.name, applied[m.version][2] if m.version in applied else None)
        for m in migrations
    ]

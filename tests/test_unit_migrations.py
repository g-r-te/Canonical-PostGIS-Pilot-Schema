"""Migration discovery and checksum rules (no database required)."""

from __future__ import annotations

from pathlib import Path

import pytest

from iris_schema import config
from iris_schema.migrations import MigrationError, checksum, discover


def _write(directory: Path, name: str, body: str = "SELECT 1;") -> None:
    (directory / name).write_text(body, encoding="utf-8")


def test_repository_migrations_are_valid_and_contiguous() -> None:
    found = discover(config.migrations_dir())
    versions = [m.version for m in found]
    assert versions == list(range(1, len(found) + 1)), "versions must be 0001..N without gaps"


def test_discover_orders_by_version(tmp_path: Path) -> None:
    _write(tmp_path, "0002_second.sql")
    _write(tmp_path, "0010_tenth.sql")
    _write(tmp_path, "0001_first.sql")
    assert [m.name for m in discover(tmp_path)] == ["first", "second", "tenth"]


@pytest.mark.parametrize(
    "bad_name", ["1_short.sql", "0001-dash.sql", "0001_UPPER.sql", "abcd_x.sql"]
)
def test_discover_rejects_bad_file_names(tmp_path: Path, bad_name: str) -> None:
    _write(tmp_path, bad_name)
    with pytest.raises(MigrationError, match="NNNN_name.sql"):
        discover(tmp_path)


def test_discover_rejects_duplicate_versions(tmp_path: Path) -> None:
    _write(tmp_path, "0001_a.sql")
    _write(tmp_path, "0001_b.sql")
    with pytest.raises(MigrationError, match="duplicate migration version 0001"):
        discover(tmp_path)


def test_discover_rejects_empty_directory(tmp_path: Path) -> None:
    with pytest.raises(MigrationError, match="no migrations"):
        discover(tmp_path)


def test_checksum_is_line_ending_independent() -> None:
    # A Windows checkout (CRLF) must not look like drift against a Linux-applied migration.
    assert checksum("CREATE TABLE t (id int);\nSELECT 1;\n") == checksum(
        "CREATE TABLE t (id int);\r\nSELECT 1;\r\n"
    )
    assert checksum("SELECT 1;") != checksum("SELECT 2;")


def test_core_contract_never_uses_a_geometry_column_name() -> None:
    for migration in discover(config.migrations_dir()):
        for line in migration.sql.splitlines():
            stripped = line.strip().lower()
            assert not stripped.startswith("geometry "), (
                f"{migration.filename}: column named 'geometry' is not allowed: {line!r}"
            )

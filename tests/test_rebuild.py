"""Reproducibility: the schema rebuilds from an empty database without manual steps."""

from __future__ import annotations

import pytest

from iris_schema import cli, config, db, migrations, seed, verify
from iris_schema.migrations import MigrationError

pytestmark = pytest.mark.db


def test_rebuild_from_empty_database(scratch_database: str) -> None:
    """Acceptance criterion 1: brand-new database (no postgis, no schemas) -> fully verified."""
    with db.connect(scratch_database) as conn:
        applied = migrations.migrate(conn, config.migrations_dir())
        assert [m.version for m in applied] == [
            m.version for m in migrations.discover(config.migrations_dir())
        ]
        for manifest in config.default_manifests():
            seed.seed(conn, manifest)
        results = verify.run_all(conn, config.verify_dir())
    failures = [f"{r.check_name}: {r.detail}" for r in results if not r.ok]
    assert not failures, "\n".join(failures)


def test_cli_rebuild_is_repeatable(scratch_database: str, capsys) -> None:
    for _ in range(2):  # second run proves reset really returns to a clean slate
        assert cli.main(["--database-url", scratch_database, "rebuild", "--yes"]) == 0
    assert "checks passed" in capsys.readouterr().out


def test_migrate_is_idempotent(scratch_database: str) -> None:
    with db.connect(scratch_database) as conn:
        assert migrations.migrate(conn, config.migrations_dir())
        assert migrations.migrate(conn, config.migrations_dir()) == []
        assert all(s.applied_at for s in migrations.status(conn, config.migrations_dir()))


def test_edited_applied_migration_is_detected(scratch_database: str) -> None:
    with db.connect(scratch_database) as conn:
        migrations.migrate(conn, config.migrations_dir())
        conn.execute(
            "UPDATE iris_meta.schema_migration SET checksum = 'tampered' WHERE version = 4"
        )
        with pytest.raises(MigrationError, match="checksum mismatch"):
            migrations.migrate(conn, config.migrations_dir())


def test_failed_migration_leaves_no_partial_state(scratch_database: str, tmp_path) -> None:
    (tmp_path / "0001_ok.sql").write_text("CREATE SCHEMA iris_core;", encoding="utf-8")
    (tmp_path / "0002_broken.sql").write_text(
        "CREATE TABLE iris_core.half (id int); SELECT no_such_function();", encoding="utf-8"
    )
    with db.connect(scratch_database) as conn:
        with pytest.raises(MigrationError, match="0002_broken.sql failed"):
            migrations.migrate(conn, tmp_path)
        (half_exists,) = conn.execute("SELECT to_regclass('iris_core.half') IS NOT NULL").fetchone()
        versions = [s.version for s in migrations.status(conn, tmp_path) if s.applied_at]
    assert not half_exists
    assert versions == [1]


def test_destructive_commands_require_confirmation(capsys) -> None:
    assert cli.main(["reset"]) == 2
    assert "--yes" in capsys.readouterr().err


def test_reset_refuses_remote_hosts(monkeypatch) -> None:
    monkeypatch.delenv("IRIS_ALLOW_REMOTE_RESET", raising=False)
    with pytest.raises(db.UnsafeResetError):
        db.assert_reset_allowed("postgresql://u:p@prod-db.example.com:5432/iris")
    db.assert_reset_allowed("postgresql://u:p@localhost:5432/iris")

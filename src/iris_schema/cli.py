"""Command line interface: ``iris-db <command>`` (or ``python -m iris_schema <command>``).

Commands
  migrate   apply pending SQL migrations
  status    show applied / pending migrations
  seed      load fixtures through staging -> promotion -> core, then derive evidence
  verify    run verification queries (exit code 1 if any check fails)
  reset     drop all project schemas (requires --yes)
  rebuild   reset + migrate + seed + verify from an empty schema (requires --yes)
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import psycopg

from . import config, db, migrations, seed, verify


def _print_seed_report(report: seed.SeedReport) -> None:
    print(f"-- {report.country_code}")
    print(
        f"{'source_id':<34} {'entity':<16} {'run':>4} {'staged':>7} {'promoted':>9} {'rejected':>9}"
    )
    for r in report.sources:
        print(
            f"{r.source_id:<34} {r.entity:<16} {r.source_run_id:>4} "
            f"{r.staged:>7} {r.promoted:>9} {r.rejected:>9}"
        )
        for feature_id, reason in r.rejections:
            print(f"    rejected {feature_id or '<no id>'}: {reason}")
    if report.evidence:
        print("evidence: " + ", ".join(f"{k}={v}" for k, v in sorted(report.evidence.items())))


def _print_verify(results: list[verify.CheckResult]) -> bool:
    for r in results:
        print(f"[{'PASS' if r.ok else 'FAIL'}] {r.check_name}\n       {r.detail}")
    failed = sum(not r.ok for r in results)
    print(f"\n{len(results) - failed}/{len(results)} checks passed")
    return failed == 0


def cmd_migrate(conn: psycopg.Connection, _: argparse.Namespace) -> int:
    applied = migrations.migrate(conn, config.migrations_dir())
    for m in applied:
        print(f"applied {m.filename}")
    print(f"{len(applied)} migration(s) applied" if applied else "schema is up to date")
    return 0


def cmd_status(conn: psycopg.Connection, _: argparse.Namespace) -> int:
    for s in migrations.status(conn, config.migrations_dir()):
        state = s.applied_at.isoformat(timespec="seconds") if s.applied_at else "PENDING"
        print(f"{s.version:04d}_{s.name:<32} {state}")
    return 0


def cmd_seed(conn: psycopg.Connection, args: argparse.Namespace) -> int:
    manifests = [Path(m) for m in args.manifest] if args.manifest else config.default_manifests()
    if not manifests:
        raise seed.ManifestError("no fixtures/*/manifest.json found")
    for manifest in manifests:
        _print_seed_report(seed.seed(conn, manifest))
    return 0


def cmd_verify(conn: psycopg.Connection, _: argparse.Namespace) -> int:
    return 0 if _print_verify(verify.run_all(conn, config.verify_dir())) else 1


def cmd_reset(conn: psycopg.Connection, args: argparse.Namespace) -> int:
    db.reset(conn)
    print("dropped schemas: " + ", ".join(config.OWNED_SCHEMAS))
    return 0


def cmd_rebuild(conn: psycopg.Connection, args: argparse.Namespace) -> int:
    for step in (cmd_reset, cmd_migrate, cmd_seed):
        print(f"== {step.__name__.removeprefix('cmd_')}")
        step(conn, args)
    print("== verify")
    return cmd_verify(conn, args)


COMMANDS = {
    "migrate": cmd_migrate,
    "status": cmd_status,
    "seed": cmd_seed,
    "verify": cmd_verify,
    "reset": cmd_reset,
    "rebuild": cmd_rebuild,
}
DESTRUCTIVE = {"reset", "rebuild"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="iris-db", description="IRIS pilot schema tooling")
    parser.add_argument(
        "--database-url",
        default=config.database_url(),
        help="PostgreSQL URL (default: $IRIS_DATABASE_URL or the docker-compose database)",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("migrate", "status", "verify"):
        sub.add_parser(name)
    for name in ("seed", "rebuild"):
        p = sub.add_parser(name)
        p.add_argument(
            "--manifest",
            action="append",
            help="fixture manifest to load (repeatable; default: fixtures/*/manifest.json)",
        )
    for name in DESTRUCTIVE:
        p = sub.choices.get(name) or sub.add_parser(name)
        p.add_argument("--yes", action="store_true", help="confirm dropping all project schemas")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command in DESTRUCTIVE:
            if not args.yes:
                print(
                    f"'{args.command}' drops all IRIS schemas; re-run with --yes", file=sys.stderr
                )
                return 2
            db.assert_reset_allowed(args.database_url)
        with db.connect(args.database_url) as conn:
            return COMMANDS[args.command](conn, args)
    except (
        migrations.MigrationError,
        seed.ManifestError,
        db.UnsafeResetError,
        psycopg.Error,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

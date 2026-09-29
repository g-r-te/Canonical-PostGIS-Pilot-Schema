"""Run the verification queries in sql/verify/.

Each ``sql/verify/NN_name.sql`` file is plain SQL (runnable with psql as well). Its final
statement must return rows of ``(check_name text, ok boolean, detail text)``. Files run inside a
transaction that is always rolled back, so they may use SET LOCAL or temporary objects.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import psycopg


@dataclass(frozen=True)
class CheckResult:
    file: str
    check_name: str
    ok: bool
    detail: str


def run_file(conn: psycopg.Connection, path: Path) -> list[CheckResult]:
    rows = None
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute(path.read_text(encoding="utf-8"))
            while True:  # keep the result set of the last statement
                if cur.description is not None:
                    rows = cur.fetchall()
                if not cur.nextset():
                    break
        raise psycopg.Rollback()  # verification never leaves state behind
    if rows is None:
        raise RuntimeError(f"{path.name}: last statement returned no rows")
    return [CheckResult(path.name, name, bool(ok), str(detail)) for name, ok, detail in rows]


def run_all(conn: psycopg.Connection, directory: Path) -> list[CheckResult]:
    files = sorted(directory.glob("*.sql"))
    if not files:
        raise RuntimeError(f"no verification files in {directory}")
    results: list[CheckResult] = []
    for path in files:
        results.extend(run_file(conn, path))
    return results

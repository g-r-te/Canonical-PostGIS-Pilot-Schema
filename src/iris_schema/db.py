"""Database connection helpers and the reset operation."""

from __future__ import annotations

import os

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from .config import LOCAL_HOSTS, OWNED_SCHEMAS


class UnsafeResetError(RuntimeError):
    """Raised when a destructive operation targets a non-local database without opt-in."""


def connect(url: str) -> psycopg.Connection:
    """Open an autocommit connection; callers scope work with ``conn.transaction()``."""
    return psycopg.connect(
        url,
        autocommit=True,
        application_name="iris-schema",
        connect_timeout=int(os.environ.get("IRIS_CONNECT_TIMEOUT", "10")),
    )


def assert_reset_allowed(url: str) -> None:
    host = conninfo_to_dict(url).get("host") or ""
    if host not in LOCAL_HOSTS and os.environ.get("IRIS_ALLOW_REMOTE_RESET") != "1":
        raise UnsafeResetError(
            f"refusing to drop schemas on non-local host {host!r}; "
            "set IRIS_ALLOW_REMOTE_RESET=1 if this is really intended"
        )


def reset(conn: psycopg.Connection) -> None:
    """Drop every schema owned by this project. The postgis extension itself is kept."""
    with conn.transaction():
        for schema in OWNED_SCHEMAS:
            conn.execute(sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(schema)))

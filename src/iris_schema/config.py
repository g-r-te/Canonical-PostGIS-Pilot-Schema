"""Runtime configuration. Everything is overridable through environment variables."""

from __future__ import annotations

import os
from pathlib import Path

# Local, non-secret defaults that match docker-compose.yml.
DEFAULT_DATABASE_URL = "postgresql://iris:iris@localhost:55432/iris"
DEFAULT_TEST_DATABASE_URL = "postgresql://iris:iris@localhost:55432/iris_test"

# Schemas owned by this project. reset drops exactly these; the postgis extension is kept.
OWNED_SCHEMAS = ("iris_core", "iris_staging", "iris_meta")

# Hosts on which `reset` is allowed without IRIS_ALLOW_REMOTE_RESET=1.
LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "db", "postgres", ""})


def project_root() -> Path:
    """Repository root (contains migrations/, sql/, fixtures/).

    Resolved from IRIS_PROJECT_ROOT, else relative to this file (editable install / checkout).
    """
    env = os.environ.get("IRIS_PROJECT_ROOT")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parents[2]


def database_url() -> str:
    return os.environ.get("IRIS_DATABASE_URL", DEFAULT_DATABASE_URL)


def migrations_dir() -> Path:
    return project_root() / "migrations"


def verify_dir() -> Path:
    return project_root() / "sql" / "verify"


def default_manifests() -> list[Path]:
    """One manifest per country: fixtures/<cc>/manifest.json, in a stable order."""
    return sorted((project_root() / "fixtures").glob("*/manifest.json"))

# Convenience wrapper; every target is a plain documented command (see README).
# Everything runs inside ./.venv (system Python on Debian/Ubuntu refuses pip installs, PEP 668).
VENV   ?= .venv
PYTHON ?= $(VENV)/bin/python
IRIS   ?= $(VENV)/bin/iris-db

.PHONY: help up down install rebuild migrate seed verify status reset test lint psql

help:
	@echo "up | install | rebuild | migrate | seed | verify | status | reset | test | lint | psql | down"

up:            ## start PostgreSQL 16 + PostGIS 3.4 and wait until healthy
	docker compose up -d --wait

down:          ## stop the database and delete its volume
	docker compose down -v

install:       ## create .venv and do an editable install with dev tools
	test -x $(PYTHON) || python3 -m venv $(VENV)
	$(PYTHON) -m pip install -e ".[dev]"

rebuild:       ## reset + migrate + seed + verify
	$(IRIS) rebuild --yes

migrate:
	$(IRIS) migrate

seed:
	$(IRIS) seed

verify:
	$(IRIS) verify

status:
	$(IRIS) status

reset:
	$(IRIS) reset --yes

test:
	$(PYTHON) -m pytest

lint:
	$(VENV)/bin/ruff check . && $(VENV)/bin/ruff format --check .

psql:
	docker compose exec db psql -U iris -d iris

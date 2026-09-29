# Convenience wrapper; every target is a plain documented command (see README).
PYTHON ?= python

.PHONY: help up down install rebuild migrate seed verify status reset test lint psql

help:
	@echo "up | install | rebuild | migrate | seed | verify | status | reset | test | lint | psql | down"

up:            ## start PostgreSQL 16 + PostGIS 3.4 and wait until healthy
	docker compose up -d --wait

down:          ## stop the database and delete its volume
	docker compose down -v

install:       ## editable install with dev tools
	$(PYTHON) -m pip install -e ".[dev]"

rebuild:       ## reset + migrate + seed + verify
	iris-db rebuild --yes

migrate:
	iris-db migrate

seed:
	iris-db seed

verify:
	iris-db verify

status:
	iris-db status

reset:
	iris-db reset --yes

test:
	$(PYTHON) -m pytest

lint:
	ruff check . && ruff format --check .

psql:
	docker compose exec db psql -U iris -d iris

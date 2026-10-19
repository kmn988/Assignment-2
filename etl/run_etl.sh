#!/usr/bin/env bash
# =====================================================================
# run_etl.sh — run the Warehouse/ETL pipeline (owner: Aravind)
#
# From the repo root, with the stack running (docker compose up -d postgres metabase):
#   ./etl/run_etl.sh          # link sources, check, stage, load, validate
#   ./etl/run_etl.sh --seed   # CLEAR the 3 source DBs, then load the team
#                             # data (db/seed/*.sql) and run the ETL.
#                             # Safe to re-run — the sources are truncated first.
#
# It runs psql inside the "ebg_postgres" container from docker-compose.yml,
# using POSTGRES_USER from .env. The warehouse tables themselves are created
# once at first start by db/init/05_warehouse.sql.
# =====================================================================
set -euo pipefail

ETL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$ETL_DIR")"
CONTAINER="${PG_CONTAINER:-ebg_postgres}"

# POSTGRES_USER from .env (default postgres)
DB_USER="postgres"
if [[ -f "$REPO_DIR/.env" ]]; then
  DB_USER="$(grep -E '^POSTGRES_USER=' "$REPO_DIR/.env" | cut -d= -f2- | tr -d '\r' || true)"
  DB_USER="${DB_USER:-postgres}"
fi

SEED=false
[[ "${1:-}" == "--seed" ]] && SEED=true

run() {   # run <database> <file>
  echo ""
  echo "==================== $2  (in $1) ===================="
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$1" < "$ETL_DIR/$2"
}

if $SEED; then
  # ---- 1. Clear the 3 source databases (warehouse + Metabase untouched) ----
  echo "==================== clearing source databases ===================="
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d inventory_db <<'SQL'
TRUNCATE inventory_movement, inventory, store, product RESTART IDENTITY CASCADE;
SQL
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d ecommerce_db <<'SQL'
TRUNCATE reservation, order_item, online_order, customer RESTART IDENTITY CASCADE;
SQL
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d pos_db <<'SQL'
TRUNCATE pos_transaction_item, pos_transaction RESTART IDENTITY CASCADE;
SQL

  # ---- 2. Load the team seed files (each one \connects to its own DB) ----
  for f in "$REPO_DIR"/db/seed/*.sql; do
    echo ""
    echo "==================== seed: $(basename "$f") ===================="
    docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres < "$f"
  done
fi

run warehouse_db 01_link_sources.sql
run warehouse_db 02_check_sources.sql
echo ">> Any MISSING TABLE / MISSING COLUMN / BAD STATUS rows above must be fixed first (see etl/README.md)."
run warehouse_db 03_staging.sql
run warehouse_db 04_etl_load.sql
run warehouse_db 05_validation.sql
echo ""
echo "Done. Check the PASS / FAIL list above."

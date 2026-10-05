-- =====================================================================
-- 01_link_sources.sql  —  EXTRACT: connect the warehouse to the 3 sources
-- Run in warehouse_db (run_etl.sh does this for you).
--
-- Our architecture keeps each system in its OWN database:
--   inventory_db · ecommerce_db · pos_db  →  warehouse_db
-- PostgreSQL can't join across databases directly, so postgres_fdw
-- ("foreign data wrapper") makes each source's tables visible inside
-- warehouse_db as read-only "foreign tables", in these schemas:
--   inventory.*  ecommerce.*  pos.*
-- The rest of the ETL reads them exactly like normal tables.
--
-- Re-run every ETL run: it re-imports the CURRENT tables, so a table a
-- teammate adds or changes is picked up automatically.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- One "server" per source database (same PostgreSQL instance, over the
-- local socket — no host or password needed for the superuser)
DROP SERVER IF EXISTS src_inventory CASCADE;
DROP SERVER IF EXISTS src_ecommerce CASCADE;
DROP SERVER IF EXISTS src_pos       CASCADE;

CREATE SERVER src_inventory FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'inventory_db');
CREATE SERVER src_ecommerce FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'ecommerce_db');
CREATE SERVER src_pos       FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'pos_db');

CREATE USER MAPPING FOR CURRENT_USER SERVER src_inventory;
CREATE USER MAPPING FOR CURRENT_USER SERVER src_ecommerce;
CREATE USER MAPPING FOR CURRENT_USER SERVER src_pos;

-- Fresh local schemas holding the foreign tables
DROP SCHEMA IF EXISTS inventory CASCADE;
DROP SCHEMA IF EXISTS ecommerce CASCADE;
DROP SCHEMA IF EXISTS pos       CASCADE;
CREATE SCHEMA inventory;
CREATE SCHEMA ecommerce;
CREATE SCHEMA pos;

-- Import every table each source owner created (in their "public" schema)
IMPORT FOREIGN SCHEMA public FROM SERVER src_inventory INTO inventory;
IMPORT FOREIGN SCHEMA public FROM SERVER src_ecommerce INTO ecommerce;
IMPORT FOREIGN SCHEMA public FROM SERVER src_pos       INTO pos;

-- What was linked (screenshot for evidence)
SELECT foreign_table_schema AS source, count(*) AS tables_linked,
       string_agg(foreign_table_name, ', ' ORDER BY foreign_table_name) AS tables
FROM information_schema.foreign_tables
GROUP BY foreign_table_schema ORDER BY 1;

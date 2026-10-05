-- =====================================================================
-- 03_staging.sql  —  EXTRACT + STAGE  (run after 01_link_sources.sql)
-- Miro "ETL Workflow" steps 1–3. Reads the inventory.* / ecommerce.* / pos.*
-- foreign tables created by 01_link_sources.sql.
--
-- Staging tables are deliberately constraint-free copies of the source
-- rows (plus load metadata) so bad data can land here and be caught by
-- the CLEAN step instead of breaking the load.
-- =====================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- ---------- Inventory system ----------
CREATE TABLE staging.stg_products AS
SELECT p.*, 'INVENTORY'::text AS source_system, now() AS extracted_at
FROM inventory.product p;

CREATE TABLE staging.stg_stores AS
SELECT s.*, 'INVENTORY'::text AS source_system, now() AS extracted_at
FROM inventory.store s;

CREATE TABLE staging.stg_inventory AS
SELECT i.inventory_id, i.product_id, i.store_id,
       i.on_hand_quantity, i.reserved_quantity,
       i.available_to_sell AS source_available_to_sell,  -- kept to reconcile against our recalculated ATS
       i.updated_at,
       'INVENTORY'::text AS source_system, now() AS extracted_at
FROM inventory.inventory i;

-- ---------- E-Commerce system ----------
CREATE TABLE staging.stg_customers AS
SELECT c.*, 'ECOMMERCE'::text AS source_system, now() AS extracted_at
FROM ecommerce.customer c;

CREATE TABLE staging.stg_online_orders AS
SELECT o.*, 'ECOMMERCE'::text AS source_system, now() AS extracted_at
FROM ecommerce.online_order o;

CREATE TABLE staging.stg_order_items AS
SELECT oi.*, 'ECOMMERCE'::text AS source_system, now() AS extracted_at
FROM ecommerce.order_item oi;

CREATE TABLE staging.stg_reservations AS
SELECT r.*, 'ECOMMERCE'::text AS source_system, now() AS extracted_at
FROM ecommerce.reservation r;

-- ---------- POS system ----------
CREATE TABLE staging.stg_pos_transactions AS
SELECT t.*, 'POS'::text AS source_system, now() AS extracted_at
FROM pos.pos_transaction t;

CREATE TABLE staging.stg_pos_items AS
SELECT ti.*, 'POS'::text AS source_system, now() AS extracted_at
FROM pos.pos_transaction_item ti;

-- Row counts extracted (screenshot this for evidence)
SELECT 'stg_products' AS table_name, count(*) FROM staging.stg_products
UNION ALL SELECT 'stg_stores',           count(*) FROM staging.stg_stores
UNION ALL SELECT 'stg_customers',        count(*) FROM staging.stg_customers
UNION ALL SELECT 'stg_online_orders',    count(*) FROM staging.stg_online_orders
UNION ALL SELECT 'stg_order_items',      count(*) FROM staging.stg_order_items
UNION ALL SELECT 'stg_reservations',     count(*) FROM staging.stg_reservations
UNION ALL SELECT 'stg_pos_transactions', count(*) FROM staging.stg_pos_transactions
UNION ALL SELECT 'stg_pos_items',        count(*) FROM staging.stg_pos_items
UNION ALL SELECT 'stg_inventory',        count(*) FROM staging.stg_inventory;

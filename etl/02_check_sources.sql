-- =====================================================================
-- 02_check_sources.sql  —  does the source data match the Miro design?
-- Runs after 01_link_sources.sql (it checks the linked foreign tables).
--
-- Compares what the ETL expects (the Miro "Relational Logical Data Model")
-- with what actually exists in the database. Every row it returns is a
-- problem to fix BEFORE the load (03 → 04 → 05).
--
--   MISSING TABLE  → teammate used a different table name or schema
--   MISSING COLUMN → teammate renamed or left out a column
--   BAD STATUS     → a status word the ETL/reports don't recognise
--   ROW COUNT      → how many rows each table has (0 = no data loaded yet)
--
-- If the first query returns no rows, the sources match the design.
-- =====================================================================

WITH expected(table_schema, table_name, column_name) AS (VALUES
  -- A. Inventory database
  ('inventory','product','product_id'), ('inventory','product','sku'), ('inventory','product','product_name'),
  ('inventory','product','category'), ('inventory','product','unit_price'), ('inventory','product','active_flag'),
  ('inventory','store','store_id'), ('inventory','store','store_name'), ('inventory','store','location'),
  ('inventory','store','active_flag'),
  ('inventory','inventory','inventory_id'), ('inventory','inventory','product_id'), ('inventory','inventory','store_id'),
  ('inventory','inventory','on_hand_quantity'), ('inventory','inventory','reserved_quantity'),
  ('inventory','inventory','available_to_sell'), ('inventory','inventory','updated_at'),
  ('inventory','inventory_movement','movement_id'), ('inventory','inventory_movement','product_id'),
  ('inventory','inventory_movement','store_id'), ('inventory','inventory_movement','movement_type'),
  ('inventory','inventory_movement','quantity_change'), ('inventory','inventory_movement','source_system'),
  ('inventory','inventory_movement','source_reference_id'), ('inventory','inventory_movement','movement_timestamp'),
  -- B. E-Commerce database
  ('ecommerce','customer','customer_id'), ('ecommerce','customer','customer_name'), ('ecommerce','customer','email'),
  ('ecommerce','online_order','order_id'), ('ecommerce','online_order','customer_id'),
  ('ecommerce','online_order','fulfilment_store_id'), ('ecommerce','online_order','order_status'),
  ('ecommerce','online_order','order_total'), ('ecommerce','online_order','created_at'), ('ecommerce','online_order','updated_at'),
  ('ecommerce','order_item','order_item_id'), ('ecommerce','order_item','order_id'), ('ecommerce','order_item','product_id'),
  ('ecommerce','order_item','quantity'), ('ecommerce','order_item','unit_price'), ('ecommerce','order_item','line_amount'),
  ('ecommerce','reservation','reservation_id'), ('ecommerce','reservation','order_id'), ('ecommerce','reservation','product_id'),
  ('ecommerce','reservation','store_id'), ('ecommerce','reservation','quantity'), ('ecommerce','reservation','reservation_status'),
  ('ecommerce','reservation','created_at'), ('ecommerce','reservation','expires_at'), ('ecommerce','reservation','released_at'),
  -- C. POS database
  ('pos','pos_transaction','transaction_id'), ('pos','pos_transaction','store_id'),
  ('pos','pos_transaction','transaction_timestamp'), ('pos','pos_transaction','transaction_status'),
  ('pos','pos_transaction','rejection_reason'), ('pos','pos_transaction','total_amount'),
  ('pos','pos_transaction_item','transaction_item_id'), ('pos','pos_transaction_item','transaction_id'),
  ('pos','pos_transaction_item','product_id'), ('pos','pos_transaction_item','quantity'),
  ('pos','pos_transaction_item','unit_price'), ('pos','pos_transaction_item','line_amount')
)
SELECT CASE WHEN t.table_name IS NULL THEN 'MISSING TABLE' ELSE 'MISSING COLUMN' END AS problem,
       e.table_schema || '.' || e.table_name AS expected_table,
       e.column_name AS expected_column,
       (SELECT string_agg(DISTINCT c2.table_schema, ', ')
          FROM information_schema.columns c2
         WHERE c2.table_name = e.table_name) AS found_this_table_in_schema
FROM expected e
LEFT JOIN information_schema.tables t
       ON t.table_schema = e.table_schema AND t.table_name = e.table_name
LEFT JOIN information_schema.columns c
       ON c.table_schema = e.table_schema AND c.table_name = e.table_name AND c.column_name = e.column_name
WHERE c.column_name IS NULL
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- Row counts per source table (run once the tables exist)
-- ---------------------------------------------------------------------
SELECT 'inventory.product' AS source_table, count(*) AS row_count FROM inventory.product
UNION ALL SELECT 'inventory.store',              count(*) FROM inventory.store
UNION ALL SELECT 'inventory.inventory',          count(*) FROM inventory.inventory
UNION ALL SELECT 'inventory.inventory_movement', count(*) FROM inventory.inventory_movement
UNION ALL SELECT 'ecommerce.customer',           count(*) FROM ecommerce.customer
UNION ALL SELECT 'ecommerce.online_order',       count(*) FROM ecommerce.online_order
UNION ALL SELECT 'ecommerce.order_item',         count(*) FROM ecommerce.order_item
UNION ALL SELECT 'ecommerce.reservation',        count(*) FROM ecommerce.reservation
UNION ALL SELECT 'pos.pos_transaction',          count(*) FROM pos.pos_transaction
UNION ALL SELECT 'pos.pos_transaction_item',     count(*) FROM pos.pos_transaction_item;

-- ---------------------------------------------------------------------
-- Status words the ETL and reports expect. Anything listed here is NOT
-- in the agreed list — agree a word with the owner, or the reports
-- will silently miss those rows. (Case and spaces are cleaned by the ETL.)
-- ---------------------------------------------------------------------
SELECT 'BAD STATUS' AS problem, 'pos.transaction_status' AS field, transaction_status AS value, count(*)
FROM pos.pos_transaction
WHERE UPPER(TRIM(transaction_status)) NOT IN ('APPROVED','REJECTED','PENDING','COMPLETED','BLOCKED') GROUP BY 3
UNION ALL
SELECT 'BAD STATUS', 'pos.rejection_reason', rejection_reason, count(*)
FROM pos.pos_transaction
WHERE rejection_reason IS NOT NULL AND UPPER(TRIM(rejection_reason)) NOT IN ('RESERVED_STOCK','OUT_OF_STOCK') GROUP BY 3
UNION ALL
SELECT 'BAD STATUS', 'ecommerce.order_status', order_status, count(*)
FROM ecommerce.online_order
WHERE UPPER(TRIM(order_status)) NOT IN ('CONFIRMED','CANCELLED','COLLECTED') GROUP BY 3
UNION ALL
SELECT 'BAD STATUS', 'ecommerce.reservation_status', reservation_status, count(*)
FROM ecommerce.reservation
WHERE UPPER(TRIM(reservation_status)) NOT IN ('ACTIVE','CANCELLED','COLLECTED','EXPIRED') GROUP BY 3;

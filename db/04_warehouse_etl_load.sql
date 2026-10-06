-- ================================================================
-- 32113 Assignment 2 - Synthetic Omnichannel Retail Dataset
-- EB Games-inspired PS5 games case study
-- PostgreSQL-compatible SQL
--
-- IMPORTANT:
-- * This is SYNTHETIC assignment data.
-- * Product names are real PS5 game titles used only as examples.
-- * Prices, stores, stock, customers, orders and transactions are fictional.
-- * Core rule: available_to_sell = on_hand_quantity - reserved_quantity
-- ================================================================

-- OWNER: Data Warehouse / ETL member
-- DEPENDENCY: Source-system tables must already contain the shared synthetic dataset.
-- This file loads staging tables, dimensions and fact tables from those sources.
\connect warehouse_db

BEGIN;

-- ==================== OPTIONAL STAGING LOADS ====================
-- Run these only if you created the staging tables listed on the Miro design.

INSERT INTO stg_products
    (product_id, sku, product_name, category, unit_price, active_flag)
SELECT product_id, sku, product_name, category, unit_price, active_flag
FROM product;

INSERT INTO stg_stores
    (store_id, store_name, location, active_flag)
SELECT store_id, store_name, location, active_flag
FROM store;

INSERT INTO stg_customers
    (customer_id, customer_name, email)
SELECT customer_id, customer_name, email
FROM customer;

INSERT INTO stg_pos_transactions
    (transaction_id, store_id, transaction_timestamp, transaction_status, rejection_reason, total_amount)
SELECT transaction_id, store_id, transaction_timestamp, transaction_status, rejection_reason, total_amount
FROM pos_transaction;

INSERT INTO stg_pos_items
    (transaction_item_id, transaction_id, product_id, quantity, unit_price, line_amount)
SELECT transaction_item_id, transaction_id, product_id, quantity, unit_price, line_amount
FROM pos_transaction_item;

INSERT INTO stg_online_orders
    (order_id, customer_id, fulfilment_store_id, order_status, order_total, created_at, updated_at)
SELECT order_id, customer_id, fulfilment_store_id, order_status, order_total, created_at, updated_at
FROM online_order;

INSERT INTO stg_order_items
    (order_item_id, order_id, product_id, quantity, unit_price, line_amount)
SELECT order_item_id, order_id, product_id, quantity, unit_price, line_amount
FROM order_item;

INSERT INTO stg_reservations
    (reservation_id, order_id, product_id, store_id, quantity, reservation_status, created_at, expires_at, released_at)
SELECT reservation_id, order_id, product_id, store_id, quantity, reservation_status, created_at, expires_at, released_at
FROM reservation;

INSERT INTO stg_inventory
    (inventory_id, product_id, store_id, on_hand_quantity, reserved_quantity, available_to_sell, updated_at)
SELECT inventory_id, product_id, store_id, on_hand_quantity, reserved_quantity, available_to_sell, updated_at
FROM inventory;

-- ==================== DIMENSIONAL WAREHOUSE LOAD ====================
-- These queries populate the dimensional model from the operational tables.
-- If your surrogate keys use IDENTITY/SERIAL, remove the explicit *_key columns.

INSERT INTO dim_product
    (product_key, product_id, sku, product_name, category, unit_price)
SELECT
    ROW_NUMBER() OVER (ORDER BY product_id) AS product_key,
    product_id, sku, product_name, category, unit_price
FROM product;

INSERT INTO dim_store
    (store_key, store_id, store_name, location)
SELECT
    ROW_NUMBER() OVER (ORDER BY store_id) AS store_key,
    store_id, store_name, location
FROM store;

INSERT INTO dim_customer
    (customer_key, customer_id, customer_name)
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_id) AS customer_key,
    customer_id, customer_name
FROM customer;

INSERT INTO dim_date
    (date_key, full_date, day, month, quarter, year, day_of_week)
SELECT DISTINCT
    TO_CHAR(d::date, 'YYYYMMDD')::INTEGER AS date_key,
    d::date AS full_date,
    EXTRACT(DAY FROM d)::INTEGER AS day,
    TO_CHAR(d, 'FMMonth') AS month,
    'Q' || EXTRACT(QUARTER FROM d)::INTEGER AS quarter,
    EXTRACT(YEAR FROM d)::INTEGER AS year,
    TO_CHAR(d, 'FMDay') AS day_of_week
FROM (
    SELECT transaction_timestamp AS d FROM pos_transaction
    UNION
    SELECT created_at FROM online_order
    UNION
    SELECT created_at FROM reservation
    UNION
    SELECT updated_at FROM inventory
) x
ORDER BY full_date;

INSERT INTO fact_pos_activity
    (pos_fact_key, transaction_id, product_key, store_key, date_key,
     quantity, unit_price, line_amount, transaction_status, rejection_reason)
SELECT
    ROW_NUMBER() OVER (ORDER BY pt.transaction_id, pti.transaction_item_id) AS pos_fact_key,
    pt.transaction_id,
    dp.product_key,
    ds.store_key,
    TO_CHAR(pt.transaction_timestamp::date, 'YYYYMMDD')::INTEGER AS date_key,
    pti.quantity,
    pti.unit_price,
    pti.line_amount,
    pt.transaction_status,
    pt.rejection_reason
FROM pos_transaction pt
JOIN pos_transaction_item pti
    ON pti.transaction_id = pt.transaction_id
JOIN dim_product dp
    ON dp.product_id = pti.product_id
JOIN dim_store ds
    ON ds.store_id = pt.store_id;

INSERT INTO fact_online_order
    (order_fact_key, order_id, product_key, store_key, customer_key, date_key,
     quantity, unit_price, line_amount, order_status)
SELECT
    ROW_NUMBER() OVER (ORDER BY oo.order_id, oi.order_item_id) AS order_fact_key,
    oo.order_id,
    dp.product_key,
    ds.store_key,
    dc.customer_key,
    TO_CHAR(oo.created_at::date, 'YYYYMMDD')::INTEGER AS date_key,
    oi.quantity,
    oi.unit_price,
    oi.line_amount,
    oo.order_status
FROM online_order oo
JOIN order_item oi
    ON oi.order_id = oo.order_id
JOIN dim_product dp
    ON dp.product_id = oi.product_id
JOIN dim_store ds
    ON ds.store_id = oo.fulfilment_store_id
JOIN dim_customer dc
    ON dc.customer_id = oo.customer_id;

INSERT INTO fact_reservation
    (reservation_fact_key, reservation_id, order_id, product_key, store_key,
     customer_key, date_key, quantity, reservation_status)
SELECT
    ROW_NUMBER() OVER (ORDER BY r.reservation_id) AS reservation_fact_key,
    r.reservation_id,
    r.order_id,
    dp.product_key,
    ds.store_key,
    dc.customer_key,
    TO_CHAR(r.created_at::date, 'YYYYMMDD')::INTEGER AS date_key,
    r.quantity,
    r.reservation_status
FROM reservation r
JOIN online_order oo
    ON oo.order_id = r.order_id
JOIN dim_product dp
    ON dp.product_id = r.product_id
JOIN dim_store ds
    ON ds.store_id = r.store_id
JOIN dim_customer dc
    ON dc.customer_id = oo.customer_id;

INSERT INTO fact_inventory_snapshot
    (inventory_fact_key, product_key, store_key, date_key,
     on_hand_quantity, reserved_quantity, available_to_sell)
SELECT
    ROW_NUMBER() OVER (ORDER BY i.store_id, i.product_id) AS inventory_fact_key,
    dp.product_key,
    ds.store_key,
    TO_CHAR(i.updated_at::date, 'YYYYMMDD')::INTEGER AS date_key,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell
FROM inventory i
JOIN dim_product dp
    ON dp.product_id = i.product_id
JOIN dim_store ds
    ON ds.store_id = i.store_id;

COMMIT;

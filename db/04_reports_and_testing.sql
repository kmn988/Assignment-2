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

-- OWNER: Reports / Dashboards / Testing member
-- Contains the three agreed report queries plus validation checks.

-- ==================== REPORT 1: INVENTORY AVAILABILITY ====================
WITH latest_snapshot AS (
    SELECT MAX(date_key) AS date_key
    FROM dw.fact_inventory_snapshot
)
SELECT
    s.store_name,
    p.product_name,
    f.on_hand_quantity,
    f.reserved_quantity,
    f.available_to_sell
FROM dw.fact_inventory_snapshot f
JOIN dw.dim_product p
    ON p.product_key = f.product_key
JOIN dw.dim_store s
    ON s.store_key = f.store_key
JOIN latest_snapshot l
    ON l.date_key = f.date_key
ORDER BY
    s.store_name,
    p.product_name;


-- ==================== REPORT 2: POS / RESERVATION CONFLICTS ====================
WITH latest_snapshot AS (
    SELECT MAX(date_key) AS date_key
    FROM dw.fact_inventory_snapshot
)
SELECT
    pos.transaction_id,
    s.store_name,
    p.product_name,
    inv.on_hand_quantity,
    inv.reserved_quantity,
    inv.available_to_sell,
    pos.transaction_status,
    pos.rejection_reason
FROM dw.fact_pos_activity pos
JOIN dw.dim_product p
    ON p.product_key = pos.product_key
JOIN dw.dim_store s
    ON s.store_key = pos.store_key
JOIN dw.fact_inventory_snapshot inv
    ON inv.product_key = pos.product_key
    AND inv.store_key = pos.store_key
JOIN latest_snapshot l
    ON l.date_key = inv.date_key
WHERE pos.transaction_status = 'BLOCKED'
ORDER BY
    s.store_name,
    p.product_name;

-- ==================== REPORT 3: OMNICHANNEL PERFORMANCE ====================
WITH pos_summary AS (
    SELECT
        store_key,
        COUNT(DISTINCT transaction_id)
            FILTER (WHERE transaction_status = 'COMPLETED')
            AS completed_pos_sales,
        COALESCE(
            SUM(line_amount)
            FILTER (WHERE transaction_status = 'COMPLETED'),
            0
        ) AS pos_revenue
    FROM dw.fact_pos_activity
    GROUP BY store_key
),

order_summary AS (
    SELECT
        store_key,
        COUNT(DISTINCT order_id) AS online_orders
    FROM dw.fact_online_order
    GROUP BY store_key
),

reservation_summary AS (
    SELECT
        store_key,
        COUNT(*) AS reservations,
           COUNT(*) FILTER (WHERE reservation_status='ACTIVE') AS active_reservations,
           COUNT(*) FILTER (WHERE reservation_status='CANCELLED') AS cancelled_reservations,
           COUNT(*) FILTER (WHERE reservation_status='EXPIRED') AS expired_reservations,
           COUNT(*) FILTER (WHERE reservation_status='COLLECTED') AS collected_reservations
    FROM dw.fact_reservation
    GROUP BY store_key
)

SELECT
    s.store_name,
    COALESCE(p.completed_pos_sales,0) AS completed_pos_sales,
    COALESCE(o.online_orders,0) AS online_orders,
    COALESCE(r.reservations,0) AS reservations,
    COALESCE(r.active_reservations,0) AS active_reservations,
    COALESCE(r.collected_reservations,0) AS collected_reservations,
    COALESCE(r.cancelled_reservations,0) AS cancelled_reservations,
    COALESCE(r.expired_reservations,0) AS expired_reservations,
    COALESCE(p.pos_revenue,0) AS pos_revenue
FROM dw.dim_store s
LEFT JOIN pos_summary p
    ON p.store_key = s.store_key
LEFT JOIN order_summary o
    ON o.store_key = s.store_key
LEFT JOIN reservation_summary r
    ON r.store_key = s.store_key
ORDER BY s.store_name;

-- ==================== MAIN END-TO-END CONFLICT CHECK ====================
SELECT
    i.store_id,
    i.product_id,
    p.product_name,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell,
    CASE
        WHEN i.on_hand_quantity > 0 AND i.available_to_sell = 0
        THEN 'PHYSICAL STOCK PRESENT BUT FULLY RESERVED'
        ELSE 'NO CONFLICT'
    END AS inventory_condition
FROM inventory.inventory i
JOIN inventory.product p ON p.product_id = i.product_id
WHERE i.available_to_sell = 0
ORDER BY i.store_id, i.product_id;

-- ==================== VALIDATION QUERIES ====================
-- 1. At least 100 inventory rows
SELECT COUNT(*) AS inventory_rows FROM inventory.inventory;

-- 2. Check ATS formula
SELECT *
FROM inventory.inventory
WHERE available_to_sell <> on_hand_quantity - reserved_quantity;

-- 3. Show products fully reserved (ATS = 0)
SELECT i.store_id, i.product_id, p.product_name,
       i.on_hand_quantity, i.reserved_quantity, i.available_to_sell
FROM inventory.inventory i
JOIN inventory.product p ON p.product_id = i.product_id
WHERE i.available_to_sell = 0;

-- 4. Show blocked POS transactions caused by reserved stock
SELECT pt.transaction_id, pt.store_id, pti.product_id, p.product_name,
       pt.transaction_status, pt.rejection_reason
FROM pos.pos_transaction pt
JOIN pos.pos_transaction_item pti ON pti.transaction_id = pt.transaction_id
JOIN inventory.product p ON p.product_id = pti.product_id
WHERE pt.transaction_status = 'BLOCKED'
  AND pt.rejection_reason = 'RESERVED_STOCK';

-- 5. Row counts for all operational tables
SELECT 'product' AS table_name, COUNT(*) AS rows FROM inventory.product
UNION ALL SELECT 'store', COUNT(*) FROM inventory.store
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory.inventory
UNION ALL SELECT 'inventory_movement', COUNT(*) FROM inventory.inventory_movement
UNION ALL SELECT 'customer', COUNT(*) FROM ecommerce.customer
UNION ALL SELECT 'online_order', COUNT(*) FROM ecommerce.online_order
UNION ALL SELECT 'order_item', COUNT(*) FROM ecommerce.order_item
UNION ALL SELECT 'reservation', COUNT(*) FROM ecommerce.reservation
UNION ALL SELECT 'pos_transaction', COUNT(*) FROM pos.pos_transaction
UNION ALL SELECT 'pos_transaction_item', COUNT(*) FROM pos.pos_transaction_item
ORDER BY table_name;

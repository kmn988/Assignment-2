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
SELECT
    s.store_name,
    p.product_name,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell
FROM inventory i
JOIN product p ON p.product_id = i.product_id
JOIN store s ON s.store_id = i.store_id
ORDER BY s.store_name, p.product_name;

-- ==================== REPORT 2: POS / RESERVATION CONFLICTS ====================
SELECT
    pt.transaction_id,
    s.store_name,
    p.product_name,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell,
    pt.transaction_status,
    pt.rejection_reason
FROM pos_transaction pt
JOIN pos_transaction_item pti
    ON pti.transaction_id = pt.transaction_id
JOIN product p
    ON p.product_id = pti.product_id
JOIN store s
    ON s.store_id = pt.store_id
LEFT JOIN inventory i
    ON i.product_id = pti.product_id
   AND i.store_id = pt.store_id
WHERE pt.transaction_status = 'BLOCKED'
ORDER BY pt.transaction_timestamp;

-- ==================== REPORT 3: OMNICHANNEL PERFORMANCE ====================
WITH pos_summary AS (
    SELECT store_id,
           COUNT(*) FILTER (WHERE transaction_status='COMPLETED') AS completed_pos_sales,
           COALESCE(SUM(total_amount) FILTER (WHERE transaction_status='COMPLETED'),0) AS pos_revenue
    FROM pos_transaction
    GROUP BY store_id
),
order_summary AS (
    SELECT fulfilment_store_id AS store_id,
           COUNT(*) AS online_orders
    FROM online_order
    GROUP BY fulfilment_store_id
),
reservation_summary AS (
    SELECT store_id,
           COUNT(*) AS reservations,
           COUNT(*) FILTER (WHERE reservation_status='ACTIVE') AS active_reservations,
           COUNT(*) FILTER (WHERE reservation_status='CANCELLED') AS cancelled_reservations
    FROM reservation
    GROUP BY store_id
)
SELECT
    s.store_name,
    COALESCE(p.completed_pos_sales,0) AS completed_pos_sales,
    COALESCE(o.online_orders,0) AS online_orders,
    COALESCE(r.reservations,0) AS reservations,
    COALESCE(r.active_reservations,0) AS active_reservations,
    COALESCE(r.cancelled_reservations,0) AS cancelled_reservations,
    COALESCE(p.pos_revenue,0) AS pos_revenue
FROM store s
LEFT JOIN pos_summary p ON p.store_id = s.store_id
LEFT JOIN order_summary o ON o.store_id = s.store_id
LEFT JOIN reservation_summary r ON r.store_id = s.store_id
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
FROM inventory i
JOIN product p ON p.product_id = i.product_id
WHERE i.available_to_sell = 0
ORDER BY i.store_id, i.product_id;

-- ==================== VALIDATION QUERIES ====================
-- 1. At least 100 inventory rows
SELECT COUNT(*) AS inventory_rows FROM inventory;

-- 2. Check ATS formula
SELECT *
FROM inventory
WHERE available_to_sell <> on_hand_quantity - reserved_quantity;

-- 3. Show products fully reserved (ATS = 0)
SELECT i.store_id, i.product_id, p.product_name,
       i.on_hand_quantity, i.reserved_quantity, i.available_to_sell
FROM inventory i
JOIN product p ON p.product_id = i.product_id
WHERE i.available_to_sell = 0;

-- 4. Show blocked POS transactions caused by reserved stock
SELECT pt.transaction_id, pt.store_id, pti.product_id, p.product_name,
       pt.transaction_status, pt.rejection_reason
FROM pos_transaction pt
JOIN pos_transaction_item pti ON pti.transaction_id = pt.transaction_id
JOIN product p ON p.product_id = pti.product_id
WHERE pt.transaction_status = 'BLOCKED'
  AND pt.rejection_reason = 'RESERVED_STOCK';

-- 5. Row counts for all operational tables
SELECT 'product' AS table_name, COUNT(*) AS rows FROM product
UNION ALL SELECT 'store', COUNT(*) FROM store
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL SELECT 'inventory_movement', COUNT(*) FROM inventory_movement
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'online_order', COUNT(*) FROM online_order
UNION ALL SELECT 'order_item', COUNT(*) FROM order_item
UNION ALL SELECT 'reservation', COUNT(*) FROM reservation
UNION ALL SELECT 'pos_transaction', COUNT(*) FROM pos_transaction
UNION ALL SELECT 'pos_transaction_item', COUNT(*) FROM pos_transaction_item
ORDER BY table_name;

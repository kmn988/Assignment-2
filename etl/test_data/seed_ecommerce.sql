-- =====================================================================
-- TEST DATA ONLY — ecommerce_db
-- Stand-in for the E-Commerce owner's tables, using the Miro names, so the
-- ETL can be demonstrated before the real data arrives.
-- Safe to re-run (CREATE TABLE IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- If the owner's real tables already exist with different columns this
-- will error — that's deliberate: use their data instead.
-- run_etl.sh --test loads it into ecommerce_db.
--
-- Scenarios (Miro frame 09): Game B @ Broadway last unit reserved (ATS 0);
-- Game C reservation cancelled (ATS 1); Game A normal sale (ATS 4).
-- =====================================================================

-- B. E-COMMERCE DATABASE
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS customer (
    customer_id    INT PRIMARY KEY,
    customer_name  VARCHAR(100) NOT NULL,
    email          VARCHAR(150) UNIQUE
);

CREATE TABLE IF NOT EXISTS online_order (
    order_id             INT PRIMARY KEY,
    customer_id          INT NOT NULL REFERENCES customer(customer_id),
    fulfilment_store_id  INT NOT NULL,      -- logical FK to inventory.store (separate system)
    order_status         VARCHAR(20) NOT NULL, -- CONFIRMED / CANCELLED / COLLECTED
    order_total          NUMERIC(10,2) NOT NULL,
    created_at           TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS order_item (
    order_item_id  INT PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES online_order(order_id),
    product_id     INT NOT NULL,
    quantity       INT NOT NULL CHECK (quantity > 0),
    unit_price     NUMERIC(10,2) NOT NULL,
    line_amount    NUMERIC(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS reservation (
    reservation_id      INT PRIMARY KEY,
    order_id            INT NOT NULL REFERENCES online_order(order_id),
    product_id          INT NOT NULL,
    store_id            INT NOT NULL,
    quantity            INT NOT NULL CHECK (quantity > 0),
    reservation_status  VARCHAR(20) NOT NULL, -- ACTIVE / CANCELLED / COLLECTED / EXPIRED
    created_at          TIMESTAMP NOT NULL,
    expires_at          TIMESTAMP,
    released_at         TIMESTAMP
);

INSERT INTO customer VALUES
 (1, 'Customer A',   'customer.a@example.com'),
 (2, 'Customer B',   'customer.b@example.com'),
 (3, 'Priya Sharma', 'priya.s@example.com'),
 (4, 'Liam Nguyen',  'liam.n@example.com') ON CONFLICT DO NOTHING;

INSERT INTO online_order VALUES
 (1001, 3, 2, 'CONFIRMED', 79.95, '2026-09-27 15:00:00', '2026-09-27 15:00:00'),
 (1002, 1, 1, 'CONFIRMED', 89.95, '2026-09-28 10:00:00', '2026-09-28 10:00:00'), -- Customer A, Game B
 (1003, 4, 1, 'CANCELLED', 69.95, '2026-09-28 12:00:00', '2026-09-28 13:30:00'), -- cancelled Game C
 (1004, 3, 3, 'COLLECTED', 59.95, '2026-09-26 09:00:00', '2026-09-26 17:00:00') ON CONFLICT DO NOTHING;

INSERT INTO order_item VALUES
 (1, 1001, 1, 1, 79.95, 79.95),
 (2, 1002, 2, 1, 89.95, 89.95),
 (3, 1003, 3, 1, 69.95, 69.95),
 (4, 1004, 5, 1, 59.95, 59.95) ON CONFLICT DO NOTHING;

INSERT INTO reservation VALUES
 (5001, 1001, 1, 2, 1, 'ACTIVE',    '2026-09-27 15:00:00', '2026-09-30 15:00:00', NULL),
 (5002, 1002, 2, 1, 1, 'ACTIVE',    '2026-09-28 10:00:00', '2026-10-01 10:00:00', NULL),  -- last unit
 (5003, 1003, 3, 1, 1, 'CANCELLED', '2026-09-28 12:00:00', '2026-10-01 12:00:00', '2026-09-28 13:30:00'),
 (5004, 1004, 5, 3, 1, 'COLLECTED', '2026-09-26 09:00:00', '2026-09-29 09:00:00', '2026-09-26 17:00:00') ON CONFLICT DO NOTHING;


-- =====================================================================
-- TEST DATA ONLY — inventory_db
-- Stand-in for the Inventory owner's tables, using the Miro names, so the
-- ETL can be demonstrated before the real data arrives.
-- Safe to re-run (CREATE TABLE IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- If the owner's real tables already exist with different columns this
-- will error — that's deliberate: use their data instead.
-- run_etl.sh --test loads it into inventory_db.
--
-- Scenarios (Miro frame 09): Game B @ Broadway last unit reserved (ATS 0);
-- Game C reservation cancelled (ATS 1); Game A normal sale (ATS 4).
-- =====================================================================

-- A. INVENTORY DATABASE
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS product (
    product_id    INT PRIMARY KEY,
    sku           VARCHAR(20) UNIQUE NOT NULL,
    product_name  VARCHAR(100) NOT NULL,
    category      VARCHAR(50),
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    active_flag   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS store (
    store_id     INT PRIMARY KEY,
    store_name   VARCHAR(100) NOT NULL,
    location     VARCHAR(100),
    active_flag  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS inventory (
    inventory_id       INT PRIMARY KEY,
    product_id         INT NOT NULL REFERENCES product(product_id),
    store_id           INT NOT NULL REFERENCES store(store_id),
    on_hand_quantity   INT NOT NULL CHECK (on_hand_quantity >= 0),
    reserved_quantity  INT NOT NULL CHECK (reserved_quantity >= 0),
    available_to_sell  INT GENERATED ALWAYS AS (on_hand_quantity - reserved_quantity) STORED,
    updated_at         TIMESTAMP NOT NULL,
    CONSTRAINT uq_inventory_product_store UNIQUE (product_id, store_id),
    CONSTRAINT ck_reserved_le_on_hand CHECK (reserved_quantity <= on_hand_quantity)
);

CREATE TABLE IF NOT EXISTS inventory_movement (
    movement_id          INT PRIMARY KEY,
    product_id           INT NOT NULL REFERENCES product(product_id),
    store_id             INT NOT NULL REFERENCES store(store_id),
    movement_type        VARCHAR(30) NOT NULL,   -- RECEIPT / RESERVE / RELEASE / SALE
    quantity_change      INT NOT NULL,
    source_system        VARCHAR(20) NOT NULL,   -- INVENTORY / ECOMMERCE / POS
    source_reference_id  VARCHAR(30),
    movement_timestamp   TIMESTAMP NOT NULL
);

INSERT INTO product VALUES
 (1, 'SKU-GA-001', 'Game A', 'Action',     79.95, TRUE),
 (2, 'SKU-GB-002', 'Game B', 'Adventure',  89.95, TRUE),
 (3, 'SKU-GC-003', 'Game C', 'Sports',     69.95, TRUE),
 (4, 'SKU-GD-004', 'Game D', 'RPG',        99.95, TRUE),
 (5, 'SKU-CT-005', 'Controller X', 'Accessory', 59.95, TRUE) ON CONFLICT DO NOTHING;

INSERT INTO store VALUES
 (1, 'Broadway',    'Broadway, Sydney NSW',    TRUE),
 (2, 'Parramatta',  'Parramatta, NSW',         TRUE),
 (3, 'Town Hall',   'Town Hall, Sydney NSW',   TRUE) ON CONFLICT DO NOTHING;

-- Current state AFTER the scenarios have happened
INSERT INTO inventory (inventory_id, product_id, store_id, on_hand_quantity, reserved_quantity, updated_at) VALUES
 (1, 1, 1, 4, 0, '2026-09-28 11:05:00'),  -- Game A  @ Broadway   : 5 -> 4 after normal sale
 (2, 2, 1, 1, 1, '2026-09-28 10:00:00'),  -- Game B  @ Broadway   : LAST UNIT, reserved -> ATS 0
 (3, 3, 1, 1, 0, '2026-09-28 13:30:00'),  -- Game C  @ Broadway   : reservation cancelled -> ATS 1
 (4, 4, 1, 2, 0, '2026-09-27 09:00:00'),  -- Game D  @ Broadway   : low stock
 (5, 1, 2, 8, 1, '2026-09-27 15:00:00'),  -- Game A  @ Parramatta : 1 active reservation
 (6, 2, 2, 3, 0, '2026-09-26 12:00:00'),
 (7, 5, 2, 10,0, '2026-09-26 12:00:00'),
 (8, 3, 3, 6, 0, '2026-09-26 12:00:00'),
 (9, 4, 3, 0, 0, '2026-09-27 16:40:00'),  -- Game D  @ Town Hall  : out of stock
 (10,5, 3, 7, 0, '2026-09-27 16:40:00') ON CONFLICT DO NOTHING;

INSERT INTO inventory_movement
 (movement_id, product_id, store_id, movement_type, quantity_change, source_system, source_reference_id, movement_timestamp) VALUES
 (1, 1, 1, 'RECEIPT',  5, 'INVENTORY', 'PO-1001',  '2026-09-25 08:00:00'),
 (2, 2, 1, 'RECEIPT',  1, 'INVENTORY', 'PO-1001',  '2026-09-25 08:00:00'),
 (3, 3, 1, 'RECEIPT',  1, 'INVENTORY', 'PO-1001',  '2026-09-25 08:00:00'),
 (4, 2, 1, 'RESERVE',  1, 'ECOMMERCE', 'RES-5002', '2026-09-28 10:00:00'),
 (5, 3, 1, 'RESERVE',  1, 'ECOMMERCE', 'RES-5003', '2026-09-28 12:00:00'),
 (6, 3, 1, 'RELEASE', -1, 'ECOMMERCE', 'RES-5003', '2026-09-28 13:30:00'),
 (7, 1, 1, 'SALE',    -1, 'POS',       'TXN-7001', '2026-09-28 11:05:00'),
 (8, 1, 2, 'RESERVE',  1, 'ECOMMERCE', 'RES-5001', '2026-09-27 15:00:00') ON CONFLICT DO NOTHING;


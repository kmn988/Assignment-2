\connect ecommerce_db

-- ================================================================
-- 32113 Assignment 2
-- E-COMMERCE SOURCE SYSTEM
-- ================================================================
-- Owner: E-Commerce Source System member
--
-- Tables:
--   1. customer
--   2. online_order
--   3. order_item
--   4. reservation
--
-- Shared IDs follow the agreed team dataset:
--   C001 = customer
--   O001 = order
--   OI001 = order item
--   P001 = product
--   S001 = store
--   R001 = reservation
--
-- Product and store master data belong to inventory_db.
-- Because PostgreSQL does not enforce foreign keys across separate
-- databases, product_id and store_id are stored here as shared
-- natural identifiers without cross-database foreign keys.
-- ================================================================

BEGIN;


-- ================================================================
-- 1. CUSTOMER
-- Stores customers who place online orders.
-- ================================================================

CREATE TABLE customer (
    customer_id     VARCHAR(20) PRIMARY KEY,
    customer_name   VARCHAR(100) NOT NULL,
    email           VARCHAR(150) NOT NULL UNIQUE
);


-- ================================================================
-- 2. ONLINE ORDER
-- Stores orders placed through the E-Commerce channel.
--
-- fulfilment_store_id refers to a store in inventory_db.
-- ================================================================

CREATE TABLE online_order (
    order_id                VARCHAR(20) PRIMARY KEY,

    customer_id             VARCHAR(20) NOT NULL
        REFERENCES customer(customer_id),

    fulfilment_store_id     VARCHAR(20) NOT NULL,

    order_status            VARCHAR(30) NOT NULL
        CHECK (
            order_status IN (
                'CONFIRMED',
                'READY_FOR_COLLECTION',
                'COLLECTED',
                'CANCELLED'
            )
        ),

    order_total             NUMERIC(10,2) NOT NULL
        CHECK (order_total >= 0),

    created_at              TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at              TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT ck_online_order_dates
        CHECK (updated_at >= created_at)
);


-- ================================================================
-- 3. ORDER ITEM
-- Stores individual product lines within each online order.
--
-- product_id refers to PRODUCT in inventory_db.
-- ================================================================

CREATE TABLE order_item (
    order_item_id   VARCHAR(20) PRIMARY KEY,

    order_id        VARCHAR(20) NOT NULL
        REFERENCES online_order(order_id),

    product_id      VARCHAR(20) NOT NULL,

    quantity        INTEGER NOT NULL
        CHECK (quantity > 0),

    unit_price      NUMERIC(10,2) NOT NULL
        CHECK (unit_price >= 0),

    line_amount     NUMERIC(10,2) NOT NULL
        CHECK (line_amount >= 0),

    CONSTRAINT ck_order_item_line_amount
        CHECK (line_amount = quantity * unit_price)
);


-- ================================================================
-- 4. RESERVATION
-- Stores the reservation lifecycle created by online orders.
--
-- product_id and store_id correspond with the shared identifiers
-- maintained by inventory_db.
-- ================================================================

CREATE TABLE reservation (
    reservation_id      VARCHAR(20) PRIMARY KEY,

    order_id            VARCHAR(20) NOT NULL
        REFERENCES online_order(order_id),

    product_id          VARCHAR(20) NOT NULL,

    store_id            VARCHAR(20) NOT NULL,

    quantity            INTEGER NOT NULL
        CHECK (quantity > 0),

    reservation_status  VARCHAR(30) NOT NULL
        CHECK (
            reservation_status IN (
                'ACTIVE',
                'CANCELLED',
                'COLLECTED',
                'EXPIRED'
            )
        ),

    created_at          TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    expires_at          TIMESTAMP,

    released_at         TIMESTAMP,

    CONSTRAINT ck_reservation_expiry
        CHECK (
            expires_at IS NULL
            OR expires_at >= created_at
        ),

    CONSTRAINT ck_reservation_release
        CHECK (
            released_at IS NULL
            OR released_at >= created_at
        )
);


-- ================================================================
-- INDEXES
-- Improve common joins and ETL extraction.
-- ================================================================

CREATE INDEX idx_online_order_customer
    ON online_order(customer_id);

CREATE INDEX idx_online_order_store
    ON online_order(fulfilment_store_id);

CREATE INDEX idx_order_item_order
    ON order_item(order_id);

CREATE INDEX idx_order_item_product
    ON order_item(product_id);

CREATE INDEX idx_reservation_order
    ON reservation(order_id);

CREATE INDEX idx_reservation_product_store
    ON reservation(product_id, store_id);

CREATE INDEX idx_reservation_status
    ON reservation(reservation_status);


COMMIT;
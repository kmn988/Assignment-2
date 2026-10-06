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


-- ================================================================
-- LIVE DEMO SUPPORT: place an online order
-- Creates the order, its item and an ACTIVE reservation, then asks
-- Inventory (a separate database, reached with dblink) to reserve
-- the stock. If Inventory refuses, the whole order is rolled back.
--
-- online_order_form is an insert-only "form" so a Metabase Action
-- (which can only run INSERT / UPDATE) can place an order.
-- Limit: the reservation in inventory_db commits on its own, so it
-- is not rolled back if something fails afterwards (nothing does
-- after it in this function).
-- ================================================================
-- BEGIN live-demo functions
CREATE EXTENSION IF NOT EXISTS dblink;

-- Shared ID format: prefix + at least 3 digits (O041, OI051, R026)
CREATE OR REPLACE FUNCTION shared_id(p_prefix TEXT, p_number INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_prefix || LPAD(p_number::TEXT, GREATEST(3, LENGTH(p_number::TEXT)), '0');
$$;

CREATE OR REPLACE FUNCTION place_online_order(
    p_customer_id VARCHAR,
    p_store_id VARCHAR,
    p_product_id VARCHAR,
    p_quantity INTEGER
)
RETURNS TABLE (
    out_order_id VARCHAR,
    out_reservation_id VARCHAR,
    out_order_status VARCHAR,
    out_reservation_status VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price     NUMERIC(10,2);
    v_total          NUMERIC(10,2);
    v_order_id       VARCHAR(20);
    v_item_id        VARCHAR(20);
    v_reservation_id VARCHAR(20);
    v_reserved       BOOLEAN;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be greater than zero';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customer WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Unknown customer %', p_customer_id;
    END IF;

    -- Product master data (and its price) belongs to inventory_db
    SELECT t.unit_price
    INTO v_unit_price
    FROM dblink(
        'dbname=inventory_db',
        format('SELECT unit_price FROM product WHERE product_id = %L', p_product_id)
    ) AS t(unit_price NUMERIC);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown product %', p_product_id;
    END IF;

    v_total := p_quantity * v_unit_price;

    -- Serialise ID generation so two orders cannot receive the same ID
    PERFORM pg_advisory_xact_lock(hashtext('ecommerce_shared_ids'));

    SELECT shared_id('O', COALESCE(MAX(regexp_replace(order_id, '\D', '', 'g')::INTEGER), 0) + 1)
    INTO v_order_id FROM online_order;

    SELECT shared_id('OI', COALESCE(MAX(regexp_replace(order_item_id, '\D', '', 'g')::INTEGER), 0) + 1)
    INTO v_item_id FROM order_item;

    SELECT shared_id('R', COALESCE(MAX(regexp_replace(reservation_id, '\D', '', 'g')::INTEGER), 0) + 1)
    INTO v_reservation_id FROM reservation;

    INSERT INTO online_order (
        order_id, customer_id, fulfilment_store_id, order_status, order_total
    )
    VALUES (v_order_id, p_customer_id, p_store_id, 'CONFIRMED', v_total);

    INSERT INTO order_item (
        order_item_id, order_id, product_id, quantity, unit_price, line_amount
    )
    VALUES (v_item_id, v_order_id, p_product_id, p_quantity, v_unit_price, v_total);

    INSERT INTO reservation (
        reservation_id, order_id, product_id, store_id, quantity,
        reservation_status, expires_at
    )
    VALUES (
        v_reservation_id, v_order_id, p_product_id, p_store_id, p_quantity,
        'ACTIVE', CURRENT_TIMESTAMP + INTERVAL '1 day'
    );

    -- Ask Inventory to reserve the stock (the reservation ID is the idempotency reference)
    SELECT r.reserved
    INTO v_reserved
    FROM dblink(
        'dbname=inventory_db',
        format('SELECT reserve_stock(%L, %L, %s, %L)',
               p_product_id, p_store_id, p_quantity, v_reservation_id)
    ) AS r(reserved BOOLEAN);

    IF v_reserved IS NOT TRUE THEN
        RAISE EXCEPTION 'Not enough available stock to reserve % x % at %',
            p_quantity, p_product_id, p_store_id;   -- rolls back the order created above
    END IF;

    RETURN QUERY SELECT v_order_id::VARCHAR, v_reservation_id::VARCHAR,
                        'CONFIRMED'::VARCHAR, 'ACTIVE'::VARCHAR;
END;
$$;

-- Insert-only form used by the Metabase "Place online order" action
CREATE OR REPLACE VIEW online_order_form AS
SELECT NULL::VARCHAR(20) AS customer_id,
       NULL::VARCHAR(20) AS store_id,
       NULL::VARCHAR(20) AS product_id,
       NULL::INTEGER     AS quantity
WHERE FALSE;

CREATE OR REPLACE FUNCTION online_order_form_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM place_online_order(NEW.customer_id, NEW.store_id, NEW.product_id, NEW.quantity);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_online_order_form ON online_order_form;
CREATE TRIGGER trg_online_order_form
INSTEAD OF INSERT ON online_order_form
FOR EACH ROW
EXECUTE FUNCTION online_order_form_insert();
-- END live-demo functions

COMMIT;
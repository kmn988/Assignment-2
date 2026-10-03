BEGIN;

CREATE SCHEMA IF NOT EXISTS inventory;

CREATE TABLE inventory.product (
    product_id INTEGER PRIMARY KEY,
    sku VARCHAR(50) NOT NULL UNIQUE,
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(50) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    active_flag BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE inventory.store (
    store_id INTEGER PRIMARY KEY,
    store_name VARCHAR(100) NOT NULL,
    location VARCHAR(150) NOT NULL,
    active_flag BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE inventory.inventory (
    inventory_id INTEGER PRIMARY KEY,
    product_id INTEGER NOT NULL REFERENCES inventory.product(product_id),
    store_id INTEGER NOT NULL REFERENCES inventory.store(store_id),
    on_hand_quantity INTEGER NOT NULL DEFAULT 0 CHECK (on_hand_quantity >= 0),
    reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
    available_to_sell INTEGER GENERATED ALWAYS AS
        (on_hand_quantity - reserved_quantity) STORED,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (product_id, store_id),
    CHECK (reserved_quantity <= on_hand_quantity)
);

CREATE TABLE inventory.inventory_movement (
    movement_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id INTEGER NOT NULL,
    store_id INTEGER NOT NULL,
    movement_type VARCHAR(30) NOT NULL,
    quantity_change INTEGER NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_reference_id VARCHAR(100),
    movement_timestamp TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id, store_id)
        REFERENCES inventory.inventory(product_id, store_id)
);

INSERT INTO inventory.product
    (product_id, sku, product_name, category, unit_price, active_flag)
VALUES
    (101, 'GAME-A', 'Game A', 'Video Games', 59.99, TRUE),
    (102, 'GAME-B', 'Game B', 'Video Games', 79.99, TRUE),
    (103, 'CTRL-01', 'Wireless Controller', 'Accessories', 89.99, TRUE),
    (104, 'HEAD-01', 'Gaming Headset', 'Accessories', 69.99, TRUE);

INSERT INTO inventory.store
    (store_id, store_name, location, active_flag)
VALUES
    (201, 'Broadway', 'Sydney', TRUE),
    (202, 'Parramatta', 'Sydney', TRUE);

INSERT INTO inventory.inventory
    (inventory_id, product_id, store_id, on_hand_quantity, reserved_quantity)
VALUES
    (1, 101, 201, 5, 0),
    (2, 102, 201, 1, 0),
    (3, 103, 201, 8, 0),
    (4, 104, 201, 4, 0),
    (5, 101, 202, 3, 0),
    (6, 102, 202, 2, 0),
    (7, 103, 202, 6, 0),
    (8, 104, 202, 3, 0);

CREATE OR REPLACE VIEW inventory.inventory_availability AS
SELECT
    i.inventory_id,
    p.product_id,
    p.sku,
    p.product_name,
    s.store_id,
    s.store_name,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell,
    i.updated_at
FROM inventory.inventory AS i
JOIN inventory.product AS p ON i.product_id = p.product_id
JOIN inventory.store AS s ON i.store_id = s.store_id;

CREATE OR REPLACE FUNCTION inventory.reserve_stock(
    p_product_id INTEGER,
    p_store_id INTEGER,
    p_quantity INTEGER,
    p_reservation_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INTEGER;
    v_previous_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Reservation quantity must be greater than zero';
    END IF;

    IF p_reservation_reference IS NULL
       OR BTRIM(p_reservation_reference) = '' THEN
        RAISE EXCEPTION 'Reservation reference is required';
    END IF;

    SELECT available_to_sell
    INTO v_available
    FROM inventory.inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT quantity_change
    INTO v_previous_quantity
    FROM inventory.inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND movement_type = 'RESERVE'
      AND source_system = 'ECOMMERCE'
      AND source_reference_id = p_reservation_reference;

    IF FOUND THEN
        IF v_previous_quantity <> p_quantity THEN
            RAISE EXCEPTION
                'This reservation reference was already used with a different quantity';
        END IF;
        RETURN TRUE;
    END IF;

    IF v_available < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory.inventory
    SET reserved_quantity = reserved_quantity + p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory.inventory_movement (
        product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id
    )
    VALUES (
        p_product_id, p_store_id, 'RESERVE',
        p_quantity, 'ECOMMERCE', p_reservation_reference
    );

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION inventory.sell_stock(
    p_product_id INTEGER,
    p_store_id INTEGER,
    p_quantity INTEGER,
    p_transaction_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INTEGER;
    v_previous_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale quantity must be greater than zero';
    END IF;

    IF p_transaction_reference IS NULL
       OR BTRIM(p_transaction_reference) = '' THEN
        RAISE EXCEPTION 'Transaction reference is required';
    END IF;

    SELECT available_to_sell
    INTO v_available
    FROM inventory.inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT quantity_change
    INTO v_previous_quantity
    FROM inventory.inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND movement_type = 'POS_SALE'
      AND source_system = 'POS'
      AND source_reference_id = p_transaction_reference;

    IF FOUND THEN
        IF v_previous_quantity <> -p_quantity THEN
            RAISE EXCEPTION
                'This transaction reference was already used with a different quantity';
        END IF;
        RETURN TRUE;
    END IF;

    IF v_available < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory.inventory
    SET on_hand_quantity = on_hand_quantity - p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory.inventory_movement (
        product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id
    )
    VALUES (
        p_product_id, p_store_id, 'POS_SALE',
        -p_quantity, 'POS', p_transaction_reference
    );

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION inventory.release_stock(
    p_product_id INTEGER,
    p_store_id INTEGER,
    p_quantity INTEGER,
    p_reservation_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_reserved_quantity INTEGER;
    v_reference_balance BIGINT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Release quantity must be greater than zero';
    END IF;

    IF p_reservation_reference IS NULL
       OR BTRIM(p_reservation_reference) = '' THEN
        RAISE EXCEPTION 'Reservation reference is required';
    END IF;

    SELECT reserved_quantity
    INTO v_reserved_quantity
    FROM inventory.inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT COALESCE(SUM(quantity_change), 0)
    INTO v_reference_balance
    FROM inventory.inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND source_system = 'ECOMMERCE'
      AND source_reference_id = p_reservation_reference
      AND movement_type IN ('RESERVE', 'RELEASE');

    IF v_reference_balance < p_quantity
       OR v_reserved_quantity < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory.inventory
    SET reserved_quantity = reserved_quantity - p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory.inventory_movement (
        product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id
    )
    VALUES (
        p_product_id, p_store_id, 'RELEASE',
        -p_quantity, 'ECOMMERCE', p_reservation_reference
    );

    RETURN TRUE;
END;
$$;

COMMIT;
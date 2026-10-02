-- One database per system, mirroring the agreed architecture:
--   3 operational (relational) systems -> ETL -> 1 dimensional warehouse
CREATE DATABASE inventory_db;
CREATE DATABASE ecommerce_db;
CREATE DATABASE pos_db;
CREATE DATABASE warehouse_db;
CREATE DATABASE metabase_db;   -- Metabase's own settings

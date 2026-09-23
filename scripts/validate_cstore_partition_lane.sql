DROP SCHEMA IF EXISTS partition_lane_validation CASCADE;
CREATE SCHEMA partition_lane_validation;
SET current_schema = partition_lane_validation;

CREATE TABLE lane_test (
    id integer NOT NULL,
    grp integer NOT NULL,
    payload numeric(18,2) NOT NULL
) WITH (orientation = column, compression = low)
PARTITION BY RANGE (id) (
    PARTITION p000 VALUES LESS THAN (100001),
    PARTITION p001 VALUES LESS THAN (200001),
    PARTITION p002 VALUES LESS THAN (300001),
    PARTITION p003 VALUES LESS THAN (400001),
    PARTITION p004 VALUES LESS THAN (500001),
    PARTITION p005 VALUES LESS THAN (600001),
    PARTITION p006 VALUES LESS THAN (700001),
    PARTITION p007 VALUES LESS THAN (MAXVALUE)
);

INSERT INTO lane_test
SELECT id, id % 97, (id % 10000)::numeric / 100
FROM generate_series(1, 800000) AS id;

ANALYZE lane_test;

SET enable_vector_engine = on;
SET enable_force_vector_engine = on;

SET query_dop = 1;
SET enable_cstore_partition_lane_scan = off;
SELECT 'dop1_stock' AS mode, count(*), sum(id), sum(grp), sum(payload) FROM lane_test;

SET query_dop = 4;
SET enable_cstore_partition_lane_scan = off;
SELECT 'dop4_stock' AS mode, count(*), sum(id), sum(grp), sum(payload) FROM lane_test;

SET enable_cstore_partition_lane_scan = on;
SELECT 'dop4_lane' AS mode, count(*), sum(id), sum(grp), sum(payload) FROM lane_test;

SET query_dop = 8;
SELECT 'dop8_lane' AS mode, count(*), sum(id), sum(grp), sum(payload) FROM lane_test;

EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT count(*), sum(id), sum(grp), sum(payload) FROM lane_test;

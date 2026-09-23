# CStore 分区扫描与 NUMA 缓存局部性优化使用说明

本文说明本分支新增的两项优化如何开启、如何确认生效，以及如何设计相互独立的对比实验：

- CStore Partition-lane Scan：把物理分区分配给不同 SMP lane，避免每个 lane 都遍历所有分区。
- NUMA-aware stream/cache placement：把工作线程和 stream 均匀放到 active NUMA groups，并让线程优先使用对应 NUMA 节点上的中间数据和共享结构。

两项优化互不依赖，可以分别开启，也可以组合使用。本文中的命令需要使用包含本提交的 release 版本 openGauss。

## 1. 使用前检查

先确认 CPU 与 NUMA 拓扑：

```bash
lscpu -e=CPU,NODE,SOCKET,ONLINE
numactl --hardware
```

NUMA 优化要求编译版本包含 libnuma 支持。最直接的检查方法是在测试实例中设置 `numa_distribute_mode = 'all'` 后重启；不带 NUMA 支持的二进制不会接受 `all`。

建议先确认使用的是 release 二进制：

```bash
$GAUSSHOME/bin/gaussdb --version
readlink -f "$GAUSSHOME/bin/gaussdb"
```

## 2. 开启 CStore Partition-lane Scan

### 2.1 生效条件

该优化只对满足以下条件的扫描生效：

1. 表是原生分区的列存表，即 `orientation=column` 且使用 `PARTITION BY RANGE`。
2. 查询使用向量化并行执行，`query_dop > 1`。
3. 执行计划包含 `Vec Part Iterator` 和 `Partitioned CStore Scan`。
4. 会话参数 `enable_cstore_partition_lane_scan` 为 `on`。

普通非分区表即使打开该参数也不会改变扫描行为。`enable_partitionwise`、`force_smp_partitionwise_scan` 和 `enable_imcsscan` 不是本优化的开关。

### 2.2 准备分区列存表

以下示例按主键范围建立 8 个物理分区。正式实验中，分区数应不少于最大 DOP；当前 TPC-H 实验建议使用 192 个分区。

```sql
CREATE TABLE tpch_part.lineitem (
    l_orderkey      bigint NOT NULL,
    l_partkey       integer NOT NULL,
    l_suppkey       integer NOT NULL,
    l_linenumber    integer NOT NULL,
    l_quantity      numeric(15,2) NOT NULL,
    l_extendedprice numeric(15,2) NOT NULL,
    l_discount      numeric(15,2) NOT NULL,
    l_tax           numeric(15,2) NOT NULL,
    l_returnflag    char(1) NOT NULL,
    l_linestatus    char(1) NOT NULL,
    l_shipdate      date NOT NULL,
    l_commitdate    date NOT NULL,
    l_receiptdate   date NOT NULL,
    l_shipinstruct  char(25) NOT NULL,
    l_shipmode      char(10) NOT NULL,
    l_comment       varchar(44) NOT NULL
) WITH (orientation=column, compression=low)
PARTITION BY RANGE (l_orderkey) (
    PARTITION p000 VALUES LESS THAN (7500001),
    PARTITION p001 VALUES LESS THAN (15000001),
    PARTITION p002 VALUES LESS THAN (22500001),
    PARTITION p003 VALUES LESS THAN (30000001),
    PARTITION p004 VALUES LESS THAN (37500001),
    PARTITION p005 VALUES LESS THAN (45000001),
    PARTITION p006 VALUES LESS THAN (52500001),
    PARTITION p007 VALUES LESS THAN (MAXVALUE)
);

INSERT INTO tpch_part.lineitem SELECT * FROM public.lineitem;
ANALYZE tpch_part.lineitem;
```

TPC-H 的 22 条查询要统一使用分区表时，所有查询涉及的大表都应在同一 schema 下建立对应分区表，并保持列名、列类型和统计信息一致。小维表可以继续使用非分区列存表。通过 `search_path` 可以在不修改 SQL 文件的情况下切换表集：

```sql
SET search_path = tpch_part, public;
```

### 2.3 开启并执行

`enable_cstore_partition_lane_scan` 是会话级参数，不需要重启数据库：

```sql
SET enable_vector_engine = on;
SET enable_force_vector_engine = on;
SET query_dop = 48;
SET enable_cstore_partition_lane_scan = on;

EXPLAIN PERFORMANCE
SELECT ...;
```

在该模式下，lane `i` 处理分区 `i, i + DOP, i + 2*DOP, ...`。一个物理分区只归一个 lane；该 lane 扫描分区内全部 CU，不再对同一分区的 CU 做第二次 `cu_id % DOP` 切分。

### 2.4 正确性和计划验证

仓库提供了一个独立验证脚本：

```bash
gsql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -p "$PORT" \
    -f scripts/validate_cstore_partition_lane.sql
```

脚本比较 DOP 1、普通 SMP 扫描和 partition-lane 扫描的聚合结果，并输出执行计划。三种模式的 `count` 和各项 `sum` 必须完全一致。

还应执行：

```sql
SHOW enable_cstore_partition_lane_scan;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT ... FROM tpch_part.lineitem ...;
```

确认计划中存在 `Vec Part Iterator`/`Partitioned CStore Scan`，且实际 DOP 没有退化为 1。

## 3. 开启 NUMA-aware stream/cache placement

### 3.1 优化范围

开启后，系统会：

1. 按 active NUMA 节点创建同等数量的 thread-pool groups，并把各组 worker 绑定到对应节点的 CPU。
2. 按 `smpIdentifier % group_count` 把同一 SMP lane 的各级 stream 映射到固定 group，使一个查询的 stream 均匀分布到 active groups，并避免单一 group 提前触发 stream 上限。
3. 从对应 NUMA 节点取得 PGPROC，并利用 worker 的 NUMA preferred policy，使执行期间首次触碰的中间数据尽量落在本地内存。
4. 把必须共享的全局分配 interleave 到本实例的 active NUMA 节点，而不是整台机器的所有节点。

该优化不会复制磁盘上的 CStore 基表，也不会自动改变基表的物理分区键。表扫描的数据局部性需要通过上一节的物理分区和 partition-lane scan 单独解决。

### 3.2 配置约束

- `enable_thread_pool` 必须为 `on`。
- `numa_distribute_mode` 必须为 `all`。
- `thread_pool_attr` 的 group 数必须等于 active NUMA 节点数。
- partial-scope 实验当前只支持从 node 0 开始的连续 NUMA 前缀，例如 `0`、`0-1`、`0-3`；不支持只选 `2-3`。
- `thread_pool_attr` 不能使用 `nobind`。推荐显式使用 `cpubind`，CPU 列表必须与 active NUMA 范围一致。
- `xloginsert_locks` 应能被 active NUMA 节点数整除。若实验覆盖 1 至 8 个节点，可使用 `840`。
- 这些参数都是启动期配置，修改后必须完整重启数据库。

### 3.3 配置示例

假设机器每个 NUMA 节点有 24 个逻辑 CPU，DOP 48 使用 CPU 0-47、NUMA node 0-1。`postgresql.conf` 可配置为：

```conf
enable_thread_pool = on
numa_distribute_mode = 'all'
xloginsert_locks = 840

# 5 * DOP 个线程容量，2 个 group 对应 node 0 和 node 1
thread_pool_attr = '240,2,(cpubind: 0-47)'
thread_pool_stream_attr = '240,0.2,1,(cpubind: 0-47)'
```

若使用 DOP 192、CPU 0-191、NUMA node 0-7，则改为：

```conf
thread_pool_attr = '960,8,(cpubind: 0-191)'
thread_pool_stream_attr = '960,0.2,1,(cpubind: 0-191)'
```

启动时再限制实例只能使用同一组 CPU 和内存节点：

```bash
CPU_RANGE=0-47
NUMA_NODES=0-1

numactl --physcpubind="$CPU_RANGE" --membind="$NUMA_NODES" \
    "$GAUSSHOME/bin/gs_ctl" start \
    -D "$PGDATA" -Z single_node -o "-p $PORT" -t 120 -w \
    -l "$RESULT_DIR/gaussdb.log"
```

不要在 local-memory 组使用 `--interleave=all`，否则进程可以把页面放到实验范围之外的节点。代码内部会对确实需要共享的全局分配在 active nodes 内做 interleave。

### 3.4 验证是否生效

连接数据库检查启动参数：

```sql
SHOW enable_thread_pool;
SHOW numa_distribute_mode;
SHOW thread_pool_attr;
SHOW thread_pool_stream_attr;
```

服务器日志应包含类似信息：

```text
InitNuma numaNodeNum: 2 numa_distribute_mode: all inheritThreadPool: 1
InitProcGlobal nNumaNodes: 2, inheritThreadPool: 1, groupNum: 2
```

如果出现 `Fail to check NUMA distribute support in thread pool`、group 数与 active NUMA 数不一致或 non-prefix NUMA scope 警告，则不能把该轮结果视为 NUMA 优化结果。

运行查询时可以辅助观察线程和内存位置：

```bash
POSTMASTER_PID=$(head -1 "$PGDATA/postmaster.pid")
taskset -pc "$POSTMASTER_PID"
numastat -p "$POSTMASTER_PID"
ps -L -p "$POSTMASTER_PID" -o pid,tid,psr,pcpu,comm --sort=psr
```

## 4. 推荐对比实验

为避免把“表分区”和“NUMA 本地内存”混为一个效果，建议先分别比较，再组合：

| 组别 | 表 | Partition-lane | NUMA placement | 目的 |
|---|---|---:|---:|---|
| P0 | 原始非分区 CStore | off | off | 原始基线 |
| P1 | RANGE 分区 CStore | off | off | 分区表本身的代价/收益 |
| P2 | 与 P1 相同 | on | off | partition-lane scan 的净收益 |
| N0 | 与 P2 相同 | on | off | NUMA 对比基线 |
| N1 | 与 P2 相同 | on | on | stream/cache NUMA 局部性的净收益 |

NUMA baseline 建议保持相同 CPU 范围和 DOP，但使用：

```conf
numa_distribute_mode = 'none'
thread_pool_attr = '<5*DOP>,1,(nobind)'
thread_pool_stream_attr = '<5*DOP>,0.2,1,(nobind)'
```

并用 `numactl --physcpubind=<CPU_RANGE> --interleave=<ACTIVE_NUMA_NODES>` 启动。N0 与 N1 除 NUMA placement 配置外，表、SQL、DOP、缓存冷热状态和运行顺序都应一致。

每个点至少预热 1 次、正式运行 3 次。性能口径使用 `EXPLAIN PERFORMANCE` 的 `Total runtime`，不要用包含连接和日志落盘时间的外层 wall time。正式结果同时保留均值、最小值、最大值和标准差。

## 5. 同时开启两项优化

数据库按第 3 节配置并重启后，在查询会话中执行：

```sql
SET search_path = tpch_part, public;
SET enable_vector_engine = on;
SET enable_force_vector_engine = on;
SET enable_cstore_partition_lane_scan = on;
SET query_dop = 48;

EXPLAIN PERFORMANCE
SELECT ...;
```

此时表扫描层由不同 lane 覆盖互不重叠的物理分区，执行层把 lane 对应的 stream 固定分散到 NUMA groups；执行过程中由本地 worker 首次触碰的中间结果更可能保留在本节点。基表数据、跨 group 的必要共享状态以及操作系统页缓存仍可能产生远端访问，因此不能把该模式描述为“完全消除跨 NUMA 访问”。

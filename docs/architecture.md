# Architecture Notes

## 目标

目标是支撑 100 亿文件数量级的 JuiceFS metadata。数据放在 RustFS，元数据默认使用 TiKV 集群承载；Aerospike 作为低延迟、高 QPS 的候选路线，需要配套 JuiceFS metadata driver 和数据模型验证。

## 推荐拓扑

默认生产起步：

```text
3 PD + 24 TiKV
```

高并发或单文件元数据偏大的场景：

```text
5 PD + 36 TiKV
```

## 故障域

节点应均匀分布到 3 个 AZ 或 3 个独立故障域。TiUP topology 中给每个 TiKV 节点设置：

```yaml
server.labels:
  zone: az-a
  host: tikv-1
```

PD 配置：

```yaml
replication.location-labels: ["zone", "host"]
replication.max-replicas: 3
```

## 容量口径

不要直接使用磁盘标称容量作为容量口径。建议用“安全可用 SSD”参与估算，例如 3.84 TB NVMe 只按约 2.8-3.2 TiB 参与容量规划。

原因包括：

- TiKV 三副本。
- RocksDB compaction 放大。
- 预留空间。
- 运维扩缩容过程中的临时水位。

## TiKV 节点数公式

```text
ceil(files * metadata_kib / 1024 / 1024 / 1024 * replicas * headroom / usable_ssd_tib)
```

建议把 `headroom` 取 `1.8-2.5`。对百亿文件生产环境，低于 18 个 TiKV 节点通常风险较高。

## Aerospike 候选拓扑

Aerospike 方案不需要 PD，但需要至少 3 个故障域内的均匀节点分布。建议从下面的验证规模开始：

```text
12 Aerospike nodes for schema PoC
24-48 Aerospike nodes for production-like validation
```

Aerospike 的关键容量项不是 RocksDB compaction，而是 primary index、secondary index 和 record payload：

```text
records = files * records_per_file
primary_index = records * 64 bytes * replication_factor
secondary_index = records * secondary_index_entries * 14 bytes * replication_factor
data = records * average_record_payload * replication_factor
```

对 100 亿文件，如果每个文件平均映射为 4 条 metadata records、RF=2，仅 primary index 就约 4.66 TiB。因此 Aerospike 节点的安全可用 RAM 是首要规划参数。

## Aerospike 数据模型要求

JuiceFS metadata 在 Aerospike 上不能依赖全表 scan。至少要为以下访问路径设计专门 record schema：

- inode attr direct lookup。
- parent inode + filename 的 dentry direct lookup。
- 可分页 readdir 的 directory index records。
- inode + chunk index 的 chunk metadata lookup。
- rename、link、unlink 的 generation/CAS 和补偿流程。
- fsck、dump、trash cleanup 的 partition-aware scan。

如果这些路径没有完成，Aerospike 只能作为点查性能原型，不能作为百亿级生产 metadata engine。

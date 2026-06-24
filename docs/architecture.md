# Architecture Notes

## 目标

目标是支撑 100 亿文件数量级的 JuiceFS metadata。数据放在 RustFS，元数据使用 TiKV 集群承载。

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

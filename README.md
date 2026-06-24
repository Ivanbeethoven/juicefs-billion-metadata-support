# 百亿级 JuiceFS 部署支持：TiKV / Aerospike + RustFS

面向 **100 亿文件数量级** 的 JuiceFS 部署骨架：

```text
JuiceFS client / CSI / Hadoop SDK
        | metadata
        v
Dedicated TiKV: 3/5 PD + 18-48 TiKV
or experimental Aerospike: 12-48+ nodes
        | objects
        v
RustFS
```

核心判断：百亿级 JuiceFS 元数据不要按 3 台、5 台小集群设计。默认生产主线推荐从 **3 PD + 24 TiKV** 起步；高 metadata QPS、目录操作密集或单文件元数据偏大的场景，评估 **5 PD + 36 TiKV** 或更高规模。Aerospike 是低延迟、高 QPS 的候选方案，但需要 JuiceFS Aerospike metadata driver 完成生产级 schema、事务和扫描路径验证。

## 推荐规模

| 档位 | 场景 | PD | TiKV | 每台 TiKV 建议 |
| --- | --- | ---: | ---: | --- |
| PoC/压测 | 10 亿级验证 | 3 | 6-9 | 16-32 vCPU, 64-128 GB RAM, 2-4 TB NVMe |
| 生产起步 | 100 亿文件，低到中等 metadata QPS | 3 | 18-24 | 32 vCPU, 128 GB RAM, 3.84 TB NVMe, 25 GbE |
| 高并发生产 | 100 亿文件，高 metadata QPS | 5 | 30-48 | 32-64 vCPU, 128-256 GB RAM, 3.84/7.68 TB NVMe, 25/100 GbE |

默认生产起步：

```text
3 PD + 24 TiKV
RustFS 独立集群 + 独立 bucket
3 个 AZ/机架故障域
TiKV 3 副本
```

## 容量估算

```text
TiKV 节点数 =
ceil(文件数 * 单文件逻辑元数据 * 副本数 * RocksDB/compaction/headroom 系数 / 单节点安全可用 SSD)
```

默认参数：

```text
文件数 = 10B
单文件逻辑元数据 = 1-2 KiB
副本数 = 3
RocksDB/compaction/headroom = 1.8-2.5
单节点安全可用 SSD = 2.8-3.2 TiB
```

示例：

```text
10B files * 1 KiB ~= 9.3 TiB logical metadata
3 replicas ~= 28 TiB
headroom 1.8-2.5 ~= 50-70 TiB raw SSD
50-70 TiB / 3 TiB ~= 17-24 TiKV nodes
```

估算脚本：

```bash
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 1 --usable-ssd-tib 3
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 2 --usable-ssd-tib 3
```

如果平均每文件元数据接近 `2 KiB`，优先评估 `30-40` 个 TiKV 节点。

## Aerospike 候选方案

Aerospike 适合作为 **高频点查、低延迟、成本敏感** 的 metadata 研发路线。它的容量首先受 primary index 约束，Aerospike 官方容量模型中每条 record 的 primary index metadata 成本为 `64 bytes * replication factor`。如果 100 亿文件被建模成平均 4 条 Aerospike record：

```text
10B files * 4 records/file * 64 bytes * RF=2 ~= 4.66 TiB primary index
```

推荐起步：

| 档位 | 场景 | Aerospike 节点 | 每台建议 |
| --- | --- | ---: | --- |
| PoC/压测 | driver schema 验证 | 6-12 | 16-32 vCPU, 128-192 GB RAM, 2-4 TB NVMe |
| 生产验证 | 100 亿文件，点查为主 | 24-48 | 32-64 vCPU, 192-384 GB RAM, 3.84/7.68 TB NVMe |
| 高并发生产 | 高 stat/open QPS | 48+ | 64 vCPU, 384 GB+ RAM, 25/100 GbE |

估算脚本：

```bash
python scripts/capacity_calculator.py \
  --engine aerospike \
  --files 10000000000 \
  --records-per-file 4 \
  --aerospike-rf 2 \
  --record-bytes 512 \
  --secondary-indexes 1 \
  --ram-per-node-gib 192 \
  --ssd-per-node-tib 3
```

注意：Aerospike 数据库可以支撑百亿级 records，但 JuiceFS metadata 不是纯点查 KV。生产化必须先解决目录分页、prefix/range scan、多 key 一致性、rename/unlink 原子性和 crash recovery。详见 [Aerospike metadata option](docs/aerospike.md)。

## 仓库内容

```text
docs/                 架构、运维、参考资料
examples/             集群配置示例
scripts/              容量估算、TiUP topology 生成
terraform/aws/        AWS 机器和安全组骨架
tiup/                 TiUP topology 示例
```

## 快速流程

### 1. 创建基础设施

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
terraform output -json > ../../examples/terraform-output.json
```

Terraform 只创建机器、安全组和 inventory。TiKV 安装、升级、扩缩容交给 TiUP。

### 2. 准备 RustFS

为 JuiceFS 创建独立 RustFS bucket 和专用访问密钥：

```bash
export RUSTFS_ENDPOINT="http://rustfs.example.internal:9000"
export RUSTFS_BUCKET="juicefs-prod"
export RUSTFS_ACCESS_KEY="replace-with-access-key"
export RUSTFS_SECRET_KEY="replace-with-secret-key"
```

RustFS 通过 S3 API 对接 JuiceFS，所以 JuiceFS 参数仍使用 `--storage s3`，但实际后端是 RustFS。

### 3. 生成 TiUP topology

```bash
python ../../scripts/generate_tiup_topology.py \
  --terraform-output ../../examples/terraform-output.json \
  --output ../../tiup/topology.generated.yaml
```

重点检查：

- PD/TiKV 是否跨 3 个故障域均匀分布。
- TiKV `server.labels.zone/host` 是否正确。
- PD 是否配置 `replication.location-labels: ["zone", "host"]`。
- `raftstore.capacity` 是否小于单节点安全可用容量。

### 4. 部署 TiKV

```bash
tiup cluster deploy juicefs-tikv-meta v8.5.0 ../../tiup/topology.generated.yaml
tiup cluster start juicefs-tikv-meta
tiup cluster display juicefs-tikv-meta
tiup cluster check juicefs-tikv-meta
```

### 5. 初始化 JuiceFS

```bash
export META_URL="tikv://pd1:2379,pd2:2379,pd3:2379/juicefs-prod"

juicefs format \
  --storage s3 \
  --bucket "${RUSTFS_ENDPOINT}/${RUSTFS_BUCKET}" \
  --access-key "$RUSTFS_ACCESS_KEY" \
  --secret-key "$RUSTFS_SECRET_KEY" \
  "$META_URL" \
  juicefs-prod
```

### 6. 挂载

```bash
sudo mkdir -p /mnt/juicefs-prod /var/cache/juicefs

juicefs mount -d \
  --cache-dir /var/cache/juicefs \
  --cache-size 102400 \
  "$META_URL" \
  /mnt/juicefs-prod
```

## 生产检查

- TiKV 生产起步不少于 18 个节点，推荐 24 个节点。
- PD/TiKV/RustFS 分离部署，不混部。
- TiKV 数据盘按安全可用容量估算，不按标称容量估算。
- RustFS bucket 独立，权限、TLS、生命周期和数据保护策略已评审。
- 客户端 cache 盘独立，不与 TiKV/RustFS 数据盘共用。
- 上线前完成 metadata 压测、RustFS 数据面压测、单节点故障演练、单 AZ 故障演练。
- 监控覆盖 JuiceFS client、PD、TiKV、RustFS、磁盘、网络。
- 扩容按故障域分批进行，避免 TiKV 和 RustFS 同时大规模扰动。

## 关键风险

| 风险 | 缓解 |
| --- | --- |
| TiKV 节点过少 | 生产从 18-24 TiKV 起步 |
| 单文件元数据估算过低 | 用 1 KiB 和 2 KiB 两档估算 |
| 单大目录过多 | 业务侧做目录分片 |
| 在线 dump 大集群 | 维护窗口、限速、组合数据库层备份 |
| 客户端同时冷启动 | 分批启动、预热 cache |
| RustFS 和 TiKV 混部 | 分离部署，独立容量和监控 |

## 详细文档

- [架构说明](docs/architecture.md)
- [Aerospike metadata option](docs/aerospike.md)
- [运维 Runbook](docs/operations.md)
- [参考资料](docs/references.md)
- [TiUP topology 示例](tiup/topology.example.yaml)
- [集群配置示例](examples/cluster.example.yaml)

## 官方参考

- [JuiceFS Metadata Engine](https://juicefs.com/docs/community/databases_for_metadata/)
- [JuiceFS Metadata Backup & Recovery](https://juicefs.com/docs/community/metadata_dump_load/)
- [JuiceFS Metadata Engines Benchmark](https://juicefs.com/docs/community/metadata_engines_benchmark/)
- [TiDB Hardware and Software Requirements](https://docs.pingcap.com/tidb/stable/hardware-and-software-requirements)
- [RustFS Documentation](https://docs.rustfs.com/)
- [RustFS S3 Compatibility](https://docs.rustfs.com/features/s3-compatibility/)

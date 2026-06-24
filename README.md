# 百亿级 JuiceFS 部署方案：TiKV 元数据集群支持文件

这个仓库用于维护 **100 亿文件数量级 JuiceFS** 的部署支持文件，默认方案是：

```text
JuiceFS client / CSI / Hadoop SDK
        |
        | metadata
        v
Dedicated TiKV cluster: 3/5 PD + 18-48 TiKV
        |
        | file chunks / objects
        v
S3-compatible object storage
```

核心判断：百亿级 JuiceFS 元数据不要按 3 台、5 台小集群设计。以 100 亿文件为目标时，推荐从 **3 PD + 24 TiKV** 起步；如果目录操作高并发、单文件元数据偏大或需要更高余量，按 **5 PD + 36 TiKV** 或更高规模设计。

## 适用范围

本方案适合：

- 文件数量目标在 `10B` 量级，目录树、rename、list、stat、create、delete 等 metadata 操作压力显著。
- 数据块存储在 S3、MinIO、OSS、COS、OBS 等对象存储，TiKV 只承载 JuiceFS metadata。
- 需要多客户端挂载、Kubernetes CSI、Hadoop/Spark 或大规模离线任务共享同一个文件系统。
- 能接受先压测、再上线、再按水位滚动扩容的生产节奏。

本方案不建议：

- 把同一个 TiKV 集群同时作为 JuiceFS metadata 和 object storage。
- 在百亿级生产环境使用临时单机元数据引擎。
- 未经压测就直接把历史海量小文件导入生产集群。

## 一页结论

| 档位 | 适用场景 | PD | TiKV | 每台 TiKV 建议 | 网络 |
| --- | --- | ---: | ---: | --- | --- |
| PoC/压测 | 10 亿级验证 | 3 | 6-9 | 16-32 vCPU, 64-128 GB RAM, 2-4 TB NVMe | 10/25 GbE |
| 生产起步 | 100 亿文件，低到中等 metadata QPS | 3 | 18-24 | 32 vCPU, 128 GB RAM, 3.84 TB NVMe | 25 GbE |
| 高并发生产 | 100 亿文件，高 metadata QPS | 5 | 30-48 | 32-64 vCPU, 128-256 GB RAM, 3.84/7.68 TB NVMe | 25/100 GbE |

推荐默认值：

```text
PD: 3
TiKV: 24
TiKV usable SSD: 2.8-3.2 TiB/node
Replication: 3
Failure domains: 3 AZs or 3 independent racks
Object storage: dedicated bucket, versioning/lifecycle policy reviewed
```

如果平均每文件逻辑元数据接近 `2 KiB`，或者业务有密集 `list/stat/rename`，建议直接评估 `30-40` 个 TiKV 节点。

## 容量模型

粗略公式：

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
10B files * 1 KiB logical metadata/file ~= 9.3 TiB logical
TiKV 3 replicas ~= 28 TiB
RocksDB/compaction/headroom * 1.8-2.5 ~= 50-70 TiB raw SSD
50-70 TiB / 3 TiB ~= 17-24 TiKV nodes
```

运行估算脚本：

```bash
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 1 --usable-ssd-tib 3
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 2 --usable-ssd-tib 3
```

解释：

- `logical_metadata_tib` 是 JuiceFS 逻辑元数据量估算。
- `replicated_metadata_tib` 叠加 TiKV 三副本后的容量。
- `raw_ssd_required_tib` 叠加 RocksDB compaction、预留空间和运维水位。
- `recommended_tikv_nodes` 是最低估算节点数，生产还应结合 QPS、目录分布和故障域余量上调。

## 目标架构

### 元数据层

- 使用专用 TiKV 集群作为 JuiceFS metadata engine。
- 生产起步：`3 PD + 18-24 TiKV`。
- 高并发生产：`5 PD + 30-48 TiKV`。
- PD 和 TiKV 均跨 3 个 AZ/机架均匀分布。
- TiUP topology 中配置 `zone` 和 `host` label，并启用 PD location labels。

### 数据层

- 使用对象存储作为 JuiceFS data storage。
- 建议为生产文件系统创建独立 bucket。
- bucket 的跨区复制、版本控制、生命周期、加密和审计策略要独立评审。
- 不建议使用同一个 TiKV 集群同时承载 metadata 和 object data。

### 客户端层

- Linux FUSE mount 用于普通 POSIX 访问。
- Kubernetes 使用 JuiceFS CSI。
- Hadoop/Spark 使用 JuiceFS Hadoop Java SDK。
- 客户端本地缓存盘独立规划，不与 TiKV 数据盘共用。

## 目录结构

```text
.
├── docs/
│   ├── architecture.md
│   ├── operations.md
│   └── references.md
├── examples/
│   └── cluster.example.yaml
├── scripts/
│   ├── capacity_calculator.py
│   └── generate_tiup_topology.py
├── terraform/
│   └── aws/
│       ├── main.tf
│       ├── outputs.tf
│       ├── terraform.tfvars.example
│       └── variables.tf
└── tiup/
    └── topology.example.yaml
```

## 部署流程

### 0. 前置决策

上线前先明确这些输入：

| 输入 | 建议默认值 | 必须确认的问题 |
| --- | --- | --- |
| 文件数量 | 10B | 是否持续增长到 20B/50B |
| 平均元数据 | 1-2 KiB/file | 小文件、xattr、ACL、目录深度是否偏高 |
| metadata QPS | 压测决定 | create/delete/list/stat/rename 占比 |
| 故障域 | 3 AZ | AZ 间延迟和带宽是否满足 Raft |
| 对象存储 | S3-compatible | 延迟、吞吐、费用、生命周期 |
| 客户端规模 | 业务决定 | CSI/FUSE/Hadoop 是否同时使用 |

### 1. 创建基础设施

Terraform 只负责机器、安全组和 inventory 输出，TiKV 安装交给 TiUP。

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

默认 AWS 资源：

- PD: `m7i.xlarge`
- TiKV: `i4i.8xlarge`
- root volume: 200 GiB gp3
- TiKV 数据盘：使用实例本地 NVMe，实际挂载和格式化由后续 OS 准备步骤完成

生产需要按环境调整：

- subnet 必须覆盖 3 个 AZ。
- SSH 入站不能开放到公网。
- TiKV/PD 端口只允许集群内部和管理网络访问。
- 对象存储访问建议走私网 endpoint。

### 2. OS 和磁盘准备

每台 TiKV 节点建议：

```bash
sudo mkfs.xfs -f /dev/nvme1n1
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data
sudo chown -R tikv:tikv /data
```

建议检查：

```bash
lsblk
df -h /data
fio --filename=/data/fio-test --rw=randwrite --bs=16k --iodepth=64 --runtime=60 --time_based --direct=1 --name=tikv-disk-test
```

系统参数建议按 TiKV/PingCAP 生产文档执行，包括：

- 关闭 swap 或确保不会触发 swap。
- 设置足够的 open files、process limit。
- 校验 NTP/chrony 时间同步。
- 检查磁盘调度、文件系统和挂载参数。
- 保证节点间低延迟和稳定带宽。

### 3. 生成 TiUP topology

Terraform 输出 IP 后生成 TiUP topology：

```bash
python ../../scripts/generate_tiup_topology.py \
  --terraform-output ../../examples/terraform-output.json \
  --output ../../tiup/topology.generated.yaml
```

生成后人工检查：

- PD 是否跨故障域分布。
- TiKV 是否均匀分布到 3 个故障域。
- `server.labels.zone` 和 `server.labels.host` 是否符合真实故障域。
- `raftstore.capacity` 是否小于单节点安全可用容量。
- `storage.reserve-space` 是否留足磁盘余量。

关键 topology 配置：

```yaml
server_configs:
  pd:
    replication.location-labels: ["zone", "host"]
    replication.max-replicas: 3
  tikv:
    storage.reserve-space: 200GiB
    raftstore.capacity: 3TiB
```

### 4. 部署 TiKV

示例：

```bash
tiup cluster deploy juicefs-tikv-meta v8.5.0 ../../tiup/topology.generated.yaml
tiup cluster start juicefs-tikv-meta
tiup cluster display juicefs-tikv-meta
tiup cluster check juicefs-tikv-meta
```

版本策略：

- 生产版本要固定，不使用临时 latest。
- 先在压测环境验证 TiKV、JuiceFS client、CSI/Hadoop SDK 的组合版本。
- 升级要先演练 rolling upgrade 和 rollback。

### 5. 初始化 JuiceFS 文件系统

TiKV metadata URL 格式：

```text
tikv://<pd_addr>[,<pd_addr>...]/<prefix>
```

示例：

```bash
export META_URL="tikv://pd1:2379,pd2:2379,pd3:2379/juicefs-prod"

juicefs format \
  --storage s3 \
  --bucket https://your-bucket.s3.amazonaws.com \
  "$META_URL" \
  juicefs-prod
```

如果 TiKV/PD 启用 TLS，metadata URL 需要追加证书参数，证书路径建议使用绝对路径。

### 6. 挂载和客户端配置

Linux FUSE 示例：

```bash
sudo mkdir -p /mnt/juicefs-prod /var/cache/juicefs

juicefs mount -d \
  --cache-dir /var/cache/juicefs \
  --cache-size 102400 \
  "$META_URL" \
  /mnt/juicefs-prod
```

客户端原则：

- cache 盘和业务临时目录分开。
- 大规模客户端统一管理 JuiceFS client 版本。
- 生产不要让所有客户端同时重启或同时冷启动 cache。
- 对 metadata 敏感业务，单独监控 mount 端 metadata latency。

### 7. 压测

上线前至少做三类压测。

#### 元数据压测

覆盖：

- create
- stat
- list
- rename
- delete
- 多目录并发
- 单大目录极端场景

示例：

```bash
juicefs bench /mnt/juicefs-prod -p 16
```

也可以使用 mdtest 或业务自有小文件压测脚本。

#### 对象存储压测

覆盖：

- 小对象写入
- 大对象顺序读写
- 混合读写
- 跨 AZ 客户端访问

对象存储瓶颈会直接影响 JuiceFS 数据面吞吐，但不等同于 metadata QPS。

#### 故障演练

至少验证：

- 单 TiKV 节点宕机。
- 单 PD 节点宕机。
- 单 AZ 故障。
- TiKV 扩容一个批次。
- 客户端重启和重新挂载。

### 8. 监控

必须监控：

| 层 | 指标 |
| --- | --- |
| JuiceFS client | metadata latency, read/write latency, cache hit ratio, mount health |
| PD | leader health, region count, scheduling, store state |
| TiKV | raftstore, apply, scheduler, RocksDB compaction, write stall |
| Disk | latency, utilization, available space, IO queue |
| Network | bandwidth, packet loss, cross-AZ latency |
| Object storage | request latency, error rate, throttling, 4xx/5xx |

建议告警：

- TiKV 磁盘安全可用容量使用超过 60%-70%。
- RocksDB compaction backlog 长期堆积。
- metadata latency 持续高于业务目标。
- PD scheduling 长时间异常。
- 任一故障域内 TiKV 节点数低于设计下限。

### 9. 备份和恢复

JuiceFS 提供 `dump/load` 导出和恢复元数据：

```bash
juicefs dump "$META_URL" meta-dump.json.gz
juicefs load "$META_URL" meta-dump.json.gz
```

生产注意：

- `juicefs dump` 不提供快照一致性；如果导出期间有写入，备份可能包含不同时间点的元数据。
- 大规模文件系统直接在线 dump 可能影响系统稳定性，要谨慎使用。
- 高一致性要求场景应暂停写入或在隔离窗口执行。
- TiKV 层备份、对象存储版本控制、JuiceFS dump 应组合设计，而不是只依赖单一手段。
- 恢复演练必须包含 metadata 和 object storage 的一致性校验。

### 10. 扩容

触发扩容评估：

- TiKV 安全可用磁盘水位超过 60%-70%。
- 文件数增长进入下一档容量。
- metadata latency 长期接近 SLO 上限。
- compaction 或 write stall 频繁。
- 业务新增大量小文件或目录遍历任务。

扩容原则：

- 每批扩容节点数尽量按故障域成组增加，例如每个 AZ 增加 2-4 台。
- 扩容后观察 region 调度、磁盘水位和 latency，再进入下一批。
- 不要在业务高峰同时做大规模导入和 TiKV 扩容。
- 扩容后更新 topology、inventory、监控分组和容量模型。

## 生产上线检查清单

### 基础设施

- [ ] PD 至少 3 个节点，高并发生产评估 5 个节点。
- [ ] TiKV 生产起步不少于 18 个节点，推荐 24 个节点起步。
- [ ] TiKV 节点均匀分布到 3 个故障域。
- [ ] TiKV 数据盘按安全可用容量估算，不按标称容量估算。
- [ ] 对象存储 bucket 独立，权限、加密、生命周期策略已评审。
- [ ] 管理网络、业务网络、对象存储 endpoint 路径已确认。

### TiKV

- [ ] TiUP topology 中包含 `zone` 和 `host` label。
- [ ] PD 配置 `replication.location-labels`。
- [ ] TiKV `raftstore.capacity` 小于安全可用容量。
- [ ] 已完成单节点、单 AZ 故障演练。
- [ ] 监控和告警已接入。

### JuiceFS

- [ ] `format` 参数已评审并记录。
- [ ] metadata prefix 唯一且命名清晰。
- [ ] mount 参数、cache 目录、cache 大小已标准化。
- [ ] CSI/Hadoop/FUSE 客户端版本已固定。
- [ ] 压测报告已归档。

### 运维

- [ ] 元数据备份策略已演练。
- [ ] 恢复流程已演练。
- [ ] 扩容流程已演练。
- [ ] 升级和回滚流程已演练。
- [ ] 值班 Runbook 已更新。

## 常见风险

| 风险 | 结果 | 缓解 |
| --- | --- | --- |
| TiKV 节点过少 | 容量和 QPS 都不够，扩容窗口紧张 | 生产从 18-24 TiKV 起步 |
| 单文件元数据估算过低 | 磁盘水位提前失控 | 用 1 KiB 和 2 KiB 两档估算 |
| 单大目录过多 | list/stat 延迟异常 | 业务侧做目录分片 |
| 在线 dump 大集群 | 影响元数据服务稳定性 | 维护窗口、限速、数据库层备份组合 |
| 客户端同时冷启动 | metadata 突刺 | 分批启动、预热 cache |
| 对象存储跨区访问 | 数据面延迟高、费用高 | 使用同区 bucket 和私网 endpoint |

## 本仓库如何使用

1. 修改 `terraform/aws/terraform.tfvars`，创建基础机器。
2. 用 `terraform output -json` 导出 IP。
3. 用 `scripts/generate_tiup_topology.py` 生成 TiUP topology。
4. 人工审查 topology 中的故障域 label 和容量参数。
5. 用 TiUP 部署 TiKV。
6. 用 JuiceFS `format` 初始化文件系统。
7. 执行压测、故障演练、监控接入。
8. 按上线清单完成生产准入。

## 参考资料

- [JuiceFS: How to Set Up Metadata Engine](https://juicefs.com/docs/community/databases_for_metadata/)
- [JuiceFS: Metadata Backup & Recovery](https://juicefs.com/docs/community/metadata_dump_load/)
- [JuiceFS: Metadata Engines Benchmark](https://juicefs.com/docs/community/metadata_engines_benchmark/)
- [JuiceFS: Command Reference](https://juicefs.com/docs/community/command_reference/)
- [JuiceFS: Architecture](https://juicefs.com/docs/community/architecture/)
- [TiDB: Hardware and Software Requirements](https://docs.pingcap.com/tidb/stable/hardware-and-software-requirements)


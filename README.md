# JuiceFS Billion-Scale Metadata Support

百亿级 JuiceFS 元数据部署支持文件，默认以 TiKV 作为 JuiceFS metadata engine。

这个仓库给出一套可落地的起步骨架：容量估算、节点规模建议、AWS Terraform 机器骨架、TiUP 拓扑生成脚本、JuiceFS format 示例和上线检查清单。

## 工程判断

百亿级 JuiceFS 元数据不要按 3 台、5 台这种小集群思路设计。以 100 亿文件数量级为目标时，建议从下面三档开始评估：

| 档位 | 适用场景 | PD | TiKV | 每台 TiKV 建议 |
| --- | --- | ---: | ---: | --- |
| PoC/压测 | 10 亿级验证 | 3 | 6-9 | 16-32 vCPU, 64-128 GB RAM, 2-4 TB NVMe |
| 生产起步 | 100 亿文件，低到中等 metadata QPS | 3 | 18-24 | 32 vCPU, 128 GB RAM, 3.84 TB NVMe, 25 GbE |
| 高并发生产 | 100 亿文件，高 metadata QPS | 5 | 30-48 | 32-64 vCPU, 128-256 GB RAM, 3.84/7.68 TB NVMe, 25/100 GbE |

推荐起步方案：`3 PD + 24 TiKV`。

## 容量估算

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

如果平均每文件元数据接近 `2 KiB`，节点数应上调到约 `30-40 TiKV`。

也可以直接使用脚本：

```bash
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 1 --usable-ssd-tib 3
python scripts/capacity_calculator.py --files 10000000000 --metadata-kib 2 --usable-ssd-tib 3
```

## 仓库结构

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

## AWS 机器骨架

Terraform 只负责创建 EC2、安全组和输出 inventory。TiKV 安装、升级和扩缩容建议交给 TiUP 或 Ansible。

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
terraform output -json > ../../examples/terraform-output.json
```

生成 TiUP topology：

```bash
python ../../scripts/generate_tiup_topology.py \
  --terraform-output ../../examples/terraform-output.json \
  --output ../../tiup/topology.generated.yaml
```

部署 TiKV：

```bash
tiup cluster deploy juicefs-tikv-meta v8.5.0 ../../tiup/topology.generated.yaml
tiup cluster start juicefs-tikv-meta
tiup cluster display juicefs-tikv-meta
```

## JuiceFS format

集群部署好后：

```bash
juicefs format \
  --storage s3 \
  --bucket https://your-bucket.s3.amazonaws.com \
  "tikv://pd1:2379,pd2:2379,pd3:2379/juicefs-prod" \
  juicefs-prod
```

## 上线前检查

- PD 至少 3 个节点，生产高并发场景可以评估 5 个节点。
- TiKV 生产起步不要低于 18 个节点，推荐从 24 个节点做百亿级起步。
- TiKV 数据盘按安全可用容量估算，不按标称容量估算。
- TiKV 节点均匀分布到 3 个 AZ 或故障域。
- `server.labels` 包含 `zone` 和 `host`，PD 配置 `replication.location-labels`。
- 先做元数据压测，再做正式导入或大规模挂载。
- 监控 PD/TiKV、RocksDB、磁盘延迟、磁盘余量、Raft store 状态和 JuiceFS metadata latency。

## 参考

- [JuiceFS v0.16 release: TiKV metadata engine](https://juicefs.com/en/blog/release-notes/juicefs-release-v016)
- [JuiceFS metadata engine selection guide](https://juicefs.com/en/blog/usage-tips/juicefs-metadata-engine-selection-guide)
- [JuiceFS metadata engines benchmark](https://juicefs.com/docs/community/metadata_engines_benchmark/)
- [TiDB hardware and software requirements](https://docs.pingcap.com/tidb/stable/hardware-and-software-requirements)


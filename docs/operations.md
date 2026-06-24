# Operations Runbook

## 1. 机器准备

使用 Terraform 创建基础机器和安全组：

```bash
cd terraform/aws
terraform init
terraform apply
terraform output -json > ../../examples/terraform-output.json
```

Terraform 输出包含：

- `pd_private_ips`
- `tikv_private_ips`
- `juicefs_meta_url`

## 2. 生成 TiUP topology

```bash
python scripts/generate_tiup_topology.py \
  --terraform-output examples/terraform-output.json \
  --output tiup/topology.generated.yaml
```

生成后人工检查：

- PD 是否跨 AZ 分布。
- TiKV 是否跨 AZ 均匀分布。
- `zone` 和 `host` label 是否正确。
- TiKV `raftstore.capacity` 是否小于安全可用容量。

## 3. 部署 TiKV

```bash
tiup cluster deploy juicefs-tikv-meta v8.5.0 tiup/topology.generated.yaml
tiup cluster start juicefs-tikv-meta
tiup cluster display juicefs-tikv-meta
```

## 4. 初始化 JuiceFS

```bash
juicefs format \
  --storage s3 \
  --bucket https://your-bucket.s3.amazonaws.com \
  "tikv://pd1:2379,pd2:2379,pd3:2379/juicefs-prod" \
  juicefs-prod
```

## 5. 压测建议

上线前至少覆盖：

- mdtest 或同类元数据压测。
- 小文件创建、删除、rename、list。
- 并发客户端挂载。
- TiKV 磁盘水位、RocksDB compaction、Raft store 指标观察。
- JuiceFS metadata latency 观察。

## 6. 扩容原则

容量接近水位前提前扩容，不要等磁盘逼近满盘。建议在以下条件触发扩容评估：

- TiKV 数据盘安全可用容量使用超过 60%-70%。
- metadata latency 长期高于业务目标。
- compaction backlog 长期堆积。
- 预计文件数或目录项数量进入下一个台阶。


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

## 4. 准备 RustFS 后端

为 JuiceFS 创建独立 RustFS bucket，并准备内网 endpoint 和专用访问密钥：

```bash
export RUSTFS_ENDPOINT="http://rustfs.example.internal:9000"
export RUSTFS_BUCKET="juicefs-prod"
export RUSTFS_ACCESS_KEY="replace-with-access-key"
export RUSTFS_SECRET_KEY="replace-with-secret-key"
```

RustFS 通过 S3 API 对接 JuiceFS，所以 JuiceFS `format` 仍使用 `--storage s3`。

## 5. 初始化 JuiceFS

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

## 5a. Aerospike 候选初始化

Aerospike 路线需要使用带 Aerospike metadata driver 的 JuiceFS 构建。生产化之前，先确认 driver 已经通过随机元数据测试、crash/retry 测试、`juicefs fsck`、`mdtest` 和长时间 fio。

示例 metadata URL：

```bash
export META_URL="aerospike://as1:3000,as2:3000,as3:3000/juicefs?set=metadata"
```

格式化：

```bash
juicefs format \
  --storage s3 \
  --bucket "${RUSTFS_ENDPOINT}/${RUSTFS_BUCKET}" \
  --access-key "$RUSTFS_ACCESS_KEY" \
  --secret-key "$RUSTFS_SECRET_KEY" \
  "$META_URL" \
  juicefs-prod
```

上线前必须验证：

- 没有 metadata 路径依赖全 namespace scan。
- 大目录 `readdir` 可分页、可限速。
- `rename`、`unlink`、`mkdir`、`rmdir` 在并发和 crash 后可恢复。
- Aerospike primary index、secondary index、namespace data 使用率都有明确水位。
- 节点重启和 rolling upgrade 满足业务 SLO。

## 6. 压测建议

上线前至少覆盖：

- mdtest 或同类元数据压测。
- 小文件创建、删除、rename、list。
- 并发客户端挂载。
- TiKV 磁盘水位、RocksDB compaction、Raft store 指标观察。
- Aerospike primary index、secondary index、namespace stop-writes 水位观察。
- JuiceFS metadata latency 观察。
- RustFS 请求延迟、错误率、bucket 容量和节点健康观察。

## 7. 扩容原则

容量接近水位前提前扩容，不要等磁盘逼近满盘。建议在以下条件触发扩容评估：

- TiKV 数据盘安全可用容量使用超过 60%-70%。
- metadata latency 长期高于业务目标。
- compaction backlog 长期堆积。
- 预计文件数或目录项数量进入下一个台阶。
- RustFS bucket 容量或请求延迟接近业务 SLO。

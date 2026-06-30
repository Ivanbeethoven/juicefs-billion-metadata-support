# Operations runbook

本文只覆盖 `3 PD + 3 TiKV` 的 JuiceFS metadata 集群。默认集群名为 `juicefs-tikv-3`，PD 地址为 `10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379`。

## 集群状态

```bash
tiup cluster display juicefs-tikv-3
tiup ctl:v8.5.6 pd -u http://10.0.1.11:2379 member
tiup ctl:v8.5.6 pd -u http://10.0.1.11:2379 store
tiup ctl:v8.5.6 pd -u http://10.0.1.11:2379 region
```

期望状态：

- 3 个 PD member 都是 healthy。
- 3 个 TiKV store 都是 `Up`。
- 没有长时间 pending/down peer。
- region leader 分布没有明显集中到单节点。

## JuiceFS 状态

```bash
export META_URL="tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/juicefs-prod"

juicefs status "$META_URL"
juicefs stats /mnt/juicefs-prod
df -h /mnt/juicefs-prod
```

## 元数据备份

小规模集群可以先使用 JuiceFS dump 做统一元数据备份：

```bash
mkdir -p backups
juicefs dump "$META_URL" "backups/juicefs-prod-meta-$(date +%F-%H%M%S).json"
```

恢复到新 metadata prefix：

```bash
export NEW_META_URL="tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/juicefs-restore"
juicefs load "backups/juicefs-prod-meta.json" "$NEW_META_URL"
```

## 滚动重启

```bash
tiup cluster restart juicefs-tikv-3 --role tikv
tiup cluster restart juicefs-tikv-3 --role pd
tiup cluster display juicefs-tikv-3
```

重启前确认业务可以承受短时间抖动。三节点 TiKV 只能容忍 1 个 TiKV 节点不可用，不要同时停止多台。

## 故障演练

单节点停机：

```bash
tiup cluster stop juicefs-tikv-3 --node 10.0.1.11:20160
tiup ctl:v8.5.6 pd -u http://10.0.1.12:2379 store
juicefs status "$META_URL"
tiup cluster start juicefs-tikv-3 --node 10.0.1.11:20160
```

演练观察：

- JuiceFS create/delete/rename/list 是否继续可用。
- PD store 是否出现 `Down` 后恢复到 `Up`。
- 业务侧错误率和延迟是否在可接受范围内。

## 扩容

当 TiKV 数据盘使用率长期超过 60%-70%，或 metadata latency 持续超过业务目标，优先扩容到 `3 PD + 6 TiKV` 或 `3 PD + 9 TiKV`。

扩容流程：

```bash
cp tiup/topology.3tikv.example.yaml tiup/topology.scaleout.yaml
vi tiup/topology.scaleout.yaml
tiup cluster scale-out juicefs-tikv-3 tiup/topology.scaleout.yaml
tiup cluster display juicefs-tikv-3
```

扩容时保持新增 TiKV 在 3 个故障域内均匀分布，并设置正确的 `server.labels.zone` 和 `server.labels.host`。

## 版本升级

先在测试集群验证，再升级生产：

```bash
tiup update cluster
tiup cluster upgrade juicefs-tikv-3 v8.5.6
tiup cluster display juicefs-tikv-3
```

JuiceFS 客户端升级使用：

```bash
JUICEFS_VERSION=1.3.1 scripts/install_juicefs_binary.sh
juicefs version
sudo systemctl restart juicefs-prod.service
```

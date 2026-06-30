# JuiceFS + 3 TiKV + RustFS binary deployment

这份方案用于小规模生产、PoC、压测或验证环境：3 台服务器每台同时部署 1 个 PD 和 1 个 TiKV，第 4 台服务器部署 RustFS。4 台服务器都安装 JuiceFS 客户端，用 TiKV 保存 metadata，用 RustFS S3 API 保存对象数据。

注意：这个拓扑不是百亿级元数据方案。TiKV 采用 3 副本后，3 个 TiKV 节点的安全可用元数据容量约等于单节点安全容量再扣除 RocksDB compaction 和预留空间，适合先把部署、运维和业务模型跑通。

## 版本与下载

默认固定下面两个版本，升级前先在测试环境验证：

| 组件 | 版本 | 二进制下载 |
| --- | --- | --- |
| JuiceFS CE | `1.3.1` | `https://github.com/juicedata/juicefs/releases/download/v1.3.1/juicefs-1.3.1-linux-amd64.tar.gz` |
| JuiceFS checksum | `1.3.1` | `https://github.com/juicedata/juicefs/releases/download/v1.3.1/checksums.txt` |
| TiKV/PD via TiUP | `v8.5.6` | `https://download.pingcap.com/tidb-community-server-v8.5.6-linux-amd64.tar.gz` |
| TiUP toolkit | `v8.5.6` | `https://download.pingcap.com/tidb-community-toolkit-v8.5.6-linux-amd64.tar.gz` |
| RustFS | latest x86_64 musl | `https://dl.rustfs.com/artifacts/rustfs/release/rustfs-linux-x86_64-musl-latest.zip` |

如果是 ARM64，把 URL 中的 `linux-amd64` 替换为 `linux-arm64`，并先确认对应版本提供该架构。

## AWS Terraform 流程

推荐先用 Terraform 在 AWS 起 4 台机器：

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
terraform init
terraform apply
cd ../..
```

加载 Terraform 生成的 env：

```bash
set -a
. terraform/aws/generated/juicefs-aws.env
set +a
```

在第一台 TiKV 节点作为 VPC 内控制机部署 TiKV，并初始化 JuiceFS：

```bash
scripts/run_aws_deploy.sh
```

运行 4 节点并发 metadata test：

```bash
scripts/run_metadata_test_all_nodes.sh
```

## 脚本化流程

仓库提供了安装脚本，可以直接按下面顺序执行。先复制环境变量示例并按实际 IP、SSH key、对象存储地址和密钥修改：

```bash
cp examples/juicefs-3tikv.env.example .env
vi .env
set -a
. ./.env
set +a
```

在 3 台 TiKV 目标机器上执行系统预处理：

```bash
sudo DATA_ROOT=/data/tikv scripts/prepare_tikv_node.sh
```

在控制机安装 TiUP 和 TiKV/PD 二进制包：

```bash
scripts/install_tiup_binary.sh
```

部署 `3 PD + 3 TiKV`：

```bash
scripts/deploy_3tikv_cluster.sh
```

在每台 JuiceFS 客户端机器安装 JuiceFS 二进制：

```bash
scripts/install_juicefs_binary.sh
```

初始化 JuiceFS 并安装 systemd 挂载服务：

```bash
scripts/format_juicefs.sh
sudo -E scripts/install_juicefs_mount_service.sh
```

## 机器规划

| 主机名 | 示例 IP | 角色 | 数据目录 | 故障域 |
| --- | --- | --- | --- | --- |
| `jfs-tikv-1` | `10.0.1.11` | PD + TiKV | `/data/tikv` | `az-a` |
| `jfs-tikv-2` | `10.0.1.12` | PD + TiKV | `/data/tikv` | `az-b` |
| `jfs-tikv-3` | `10.0.1.13` | PD + TiKV | `/data/tikv` | `az-c` |
| `jfs-rustfs-1` | `10.0.1.21` | RustFS | `/data/rustfs` | `az-a` |

建议配置：

| 场景 | 每台服务器 |
| --- | --- |
| 验证/压测 | 8 vCPU, 32 GB RAM, 500 GB+ SSD/NVMe, 1/10 GbE |
| 小规模生产 | 16 vCPU, 64 GB RAM, 1-4 TB NVMe, 10 GbE |

端口：

| 组件 | 端口 | 用途 |
| --- | ---: | --- |
| SSH | 22 | TiUP 部署和运维 |
| PD | 2379 | JuiceFS/TiKV client 访问 PD |
| PD | 2380 | PD raft peer |
| TiKV | 20160 | TiKV RPC |
| TiKV | 20180 | TiKV status/metrics |
| RustFS | 9000 | S3 API |
| RustFS | 9001 | console，可选暴露 |

## 1. 系统准备

在 3 台目标机器上准备数据盘和基础系统参数。下面命令按 Rocky/RHEL 系统写，Ubuntu/Debian 可替换成等价包管理命令。

```bash
sudo mkdir -p /data/tikv
sudo chown -R root:root /data/tikv

sudo swapoff -a
sudo sed -i.bak '/ swap / s/^/#/' /etc/fstab

sudo tee /etc/sysctl.d/99-tikv.conf >/dev/null <<'EOF'
vm.swappiness = 0
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
EOF
sudo sysctl --system

echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

确保三台机器互相 DNS/hosts 可解析，时间同步正常，控制机可以通过 root 或 sudo 用户 SSH 到三台机器。

## 2. 安装 TiUP

### 在线方式

在控制机执行。控制机可以是 `jfs-tikv-1`，也可以是独立运维机。

```bash
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
source ~/.bash_profile

tiup cluster
tiup update --self
tiup update cluster
tiup --binary cluster
tiup list tikv
```

### 离线二进制方式

在可联网机器下载二进制包：

```bash
export TIDB_VERSION=v8.5.6
export TIDB_ARCH=amd64

curl -fLO "https://download.pingcap.com/tidb-community-server-${TIDB_VERSION}-linux-${TIDB_ARCH}.tar.gz"
curl -fLO "https://download.pingcap.com/tidb-community-toolkit-${TIDB_VERSION}-linux-${TIDB_ARCH}.tar.gz"
```

把两个 tarball 传到控制机后执行：

```bash
export TIDB_VERSION=v8.5.6
export TIDB_ARCH=amd64

tar xf "tidb-community-server-${TIDB_VERSION}-linux-${TIDB_ARCH}.tar.gz"
sh "tidb-community-server-${TIDB_VERSION}-linux-${TIDB_ARCH}/local_install.sh"
source ~/.bash_profile

tar xf "tidb-community-toolkit-${TIDB_VERSION}-linux-${TIDB_ARCH}.tar.gz"
cd "tidb-community-server-${TIDB_VERSION}-linux-${TIDB_ARCH}"
cp -rp keys ~/.tiup/
tiup mirror merge "../tidb-community-toolkit-${TIDB_VERSION}-linux-${TIDB_ARCH}"
tiup list tikv
```

## 3. 准备 TiUP topology

复制并修改 [tiup/topology.3tikv.example.yaml](../tiup/topology.3tikv.example.yaml) 中的 IP、目录和 `raftstore.capacity`。

容量配置建议：

- `raftstore.capacity` 设置为 TiKV 数据盘安全可用容量，不要写磁盘标称容量。
- `storage.reserve-space` 至少保留 `100GiB`，数据盘较大时可提高到 `200GiB`。
- 每台机器只部署一个 TiKV 实例时，`server.labels.host` 写物理主机名。

示例元数据访问地址：

```bash
export META_URL="tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/juicefs-prod"
```

## 4. 部署 TiKV

```bash
export CLUSTER_NAME=juicefs-tikv-3
export TIDB_VERSION=v8.5.6
export TOPOLOGY=tiup/topology.3tikv.example.yaml

tiup cluster check "$TOPOLOGY" --user root -i ~/.ssh/id_rsa
tiup cluster check "$TOPOLOGY" --apply --user root -i ~/.ssh/id_rsa

tiup cluster deploy "$CLUSTER_NAME" "$TIDB_VERSION" "$TOPOLOGY" --user root -i ~/.ssh/id_rsa
tiup cluster start "$CLUSTER_NAME"
tiup cluster display "$CLUSTER_NAME"
```

检查 PD 和 store 状态：

```bash
tiup ctl:${TIDB_VERSION} pd -u http://10.0.1.11:2379 member
tiup ctl:${TIDB_VERSION} pd -u http://10.0.1.11:2379 store
```

如果三台机器跨机架或跨可用区，确认 PD 已按 label 感知故障域：

```bash
tiup ctl:${TIDB_VERSION} pd -u http://10.0.1.11:2379 config show replication
```

## 5. 安装 JuiceFS 二进制

在每台 JuiceFS 客户端机器上执行。挂载需要 FUSE，FUSE 是系统依赖，不用容器。

```bash
export JUICEFS_VERSION=1.3.1

curl -fLO "https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_VERSION}/juicefs-${JUICEFS_VERSION}-linux-amd64.tar.gz"
curl -fLO "https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_VERSION}/checksums.txt"
grep "juicefs-${JUICEFS_VERSION}-linux-amd64.tar.gz" checksums.txt | sha256sum -c -

tar -zxf "juicefs-${JUICEFS_VERSION}-linux-amd64.tar.gz"
sudo install -m 0755 juicefs /usr/local/bin/juicefs
juicefs version
```

系统依赖示例：

```bash
# Rocky/RHEL
sudo dnf install -y fuse

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y fuse
```

## 6. 初始化 JuiceFS

对象存储按外部已有 bucket 处理。下面以 S3 兼容对象存储为例，替换 endpoint、bucket 和密钥即可。

```bash
export JFS_NAME=juicefs-prod
export META_URL="tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/${JFS_NAME}"

export JFS_STORAGE=s3
export JFS_BUCKET="https://s3.example.internal/${JFS_NAME}"
export JFS_ACCESS_KEY="replace-with-access-key"
export JFS_SECRET_KEY="replace-with-secret-key"

juicefs format \
  --storage "$JFS_STORAGE" \
  --bucket "$JFS_BUCKET" \
  --access-key "$JFS_ACCESS_KEY" \
  --secret-key "$JFS_SECRET_KEY" \
  "$META_URL" \
  "$JFS_NAME"
```

同一个 TiKV 集群承载多个 JuiceFS 文件系统时，用不同 prefix：

```text
tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/project-a
tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/project-b
```

## 7. 挂载与 systemd

手动挂载：

```bash
sudo mkdir -p /mnt/juicefs-prod /var/lib/juicefs/cache

sudo juicefs mount -d \
  --cache-dir /var/lib/juicefs/cache \
  --cache-size 102400 \
  "$META_URL" \
  /mnt/juicefs-prod

df -h /mnt/juicefs-prod
```

systemd 服务：

```ini
[Unit]
Description=JuiceFS mount juicefs-prod
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=META_URL=tikv://10.0.1.11:2379,10.0.1.12:2379,10.0.1.13:2379/juicefs-prod
ExecStart=/usr/local/bin/juicefs mount -d --cache-dir /var/lib/juicefs/cache --cache-size 102400 ${META_URL} /mnt/juicefs-prod
ExecStop=/usr/local/bin/juicefs umount /mnt/juicefs-prod
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

保存为 `/etc/systemd/system/juicefs-prod.service` 后启用：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now juicefs-prod.service
sudo systemctl status juicefs-prod.service
```

## 8. 运维检查

常用命令：

```bash
tiup cluster display juicefs-tikv-3
tiup cluster check juicefs-tikv-3
tiup ctl:v8.5.6 pd -u http://10.0.1.11:2379 store

juicefs status "$META_URL"
juicefs stats /mnt/juicefs-prod
juicefs dump "$META_URL" "juicefs-prod-meta-$(date +%F).json"
```

上线前至少验证：

- 三台机器任意宕机 1 台后，JuiceFS metadata 操作仍可读写。
- 业务典型目录下的 create/delete/rename/list 性能满足目标。
- TiKV 数据盘低于 60%-70% 水位；生产长期运行不要超过 80%。
- `pd store` 中 3 个 TiKV store 都是 `Up`。
- JuiceFS 客户端 cache 盘和 TiKV 数据盘不要共用。
- 防火墙只向 JuiceFS 客户端和运维控制机开放 PD/TiKV 端口。

后续容量增长时，优先扩到 `3 PD + 6/9 TiKV`，并保持 TiKV 节点在 3 个故障域内均匀分布。

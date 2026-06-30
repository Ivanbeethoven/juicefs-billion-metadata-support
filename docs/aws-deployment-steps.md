# AWS deployment steps

这份文档是仓库的端到端执行手册，用 Terraform 在 AWS 创建 4 台 EC2：

- 3 台 `PD + TiKV + JuiceFS client`
- 1 台 `RustFS + JuiceFS client`
- JuiceFS metadata 写入 TiKV，object data 写入 RustFS S3 API
- 4 台机器都可参与 JuiceFS metadata test，默认总目标约 1 亿小文件

实际部署时，TiUP 会从第一台 TiKV 节点公网 IP 进入 VPC，再使用私网 IP 部署 3 节点 TiKV 集群。

## 1. 前置条件

本地控制机需要：

- AWS credential 已配置好，例如 `AWS_PROFILE`、`AWS_ACCESS_KEY_ID` 或实例角色。
- Terraform `>= 1.5`。
- 能从当前公网出口 SSH 到 EC2。把你的办公网或 VPN CIDR 写入 `allowed_ssh_cidrs`。
- 本地有 `curl`，用于自动探测公网 IP；有 `openssl` 时会优先用于生成随机密钥。
- AWS 配额足够创建 4 台实例、4 块数据盘和 gp3 IOPS/throughput。
- 不要把真实 `terraform.tfvars`、生成的 env、state、pem 文件提交到仓库。

## 2. 配置 Terraform

最省事的入口是全自动部署脚本：

```bash
scripts/aws_full_deploy.sh deploy
```

它会自动生成 `terraform.tfvars`、执行 `terraform init/apply`、等待 4 台节点初始化、部署 `3 PD + 3 TiKV`，并初始化 JuiceFS。

如果希望先只生成配置再检查，使用：

```bash
scripts/generate_aws_tfvars.sh
```

脚本会自动：

- 探测当前公网 IP，并写入 `allowed_ssh_cidrs = ["<ip>/32"]`。
- 生成 32 位 shell-safe `rustfs_secret_key`。
- 写出 `terraform/aws/terraform.tfvars`，权限设为 `0600`。

生成后可以按需查看和调整：

```bash
vi terraform/aws/terraform.tfvars
```

常用覆盖方式：

```bash
AWS_REGION=us-west-2 \
PROJECT_NAME=juicefs-prod \
ALLOWED_SSH_CIDRS="203.0.113.10/32,198.51.100.20/32" \
TIKV_INSTANCE_TYPE=i4i.2xlarge \
RUSTFS_INSTANCE_TYPE=i4i.2xlarge \
scripts/generate_aws_tfvars.sh
```

如果文件已存在，脚本默认拒绝覆盖。确认要重建时：

```bash
FORCE=1 scripts/generate_aws_tfvars.sh
```

关键配置示例：

```hcl
aws_region = "us-east-1"
project_name = "juicefs-3tikv"

allowed_ssh_cidrs = ["自动探测到的公网出口/32"]
expose_rustfs_console = false

rustfs_secret_key = "脚本自动生成的随机字符串"
rustfs_bucket = "juicefs-prod"
jfs_name = "juicefs-prod"
```

默认会创建新的 EC2 key pair，并把私钥写入 `terraform/aws/generated/<project>.pem`：

```hcl
create_key_pair = true
```

如果使用已有 key pair，改成：

```hcl
create_key_pair = false
key_name = "my-existing-key"
ssh_private_key_path = "/absolute/path/to/my-existing-key.pem"
```

容量和压测参数按需调整：

```hcl
tikv_instance_type = "m6i.2xlarge"
rustfs_instance_type = "m6i.2xlarge"

tikv_data_volume_size_gb = 2048
rustfs_data_volume_size_gb = 4096
data_volume_type = "gp3"
data_volume_iops = 12000
data_volume_throughput = 500

target_total_files = 100000000
files_per_dir = 100000
test_threads = 256
```

## 3. 创建 AWS 资源

如果没有使用 `scripts/aws_full_deploy.sh deploy`，可以手动执行 Terraform：

```bash
terraform -chdir=terraform/aws init
terraform -chdir=terraform/aws apply
```

Terraform 会生成这些部署文件：

- `terraform/aws/generated/juicefs-aws.env`
- `tiup/topology.aws.generated.yaml`
- `terraform/aws/generated/<project>.pem`，仅当 `create_key_pair=true`

可以用 Terraform output 核对地址：

```bash
terraform -chdir=terraform/aws output
```

## 4. 加载部署环境

在仓库根目录加载 Terraform 生成的环境变量：

```bash
set -a
. terraform/aws/generated/juicefs-aws.env
set +a
```

关键变量包括：

- `CONTROL_HOST`：第一台 TiKV 节点公网 IP，作为 VPC 内控制机。
- `JUICEFS_TEST_HOSTS`：4 台节点公网 IP，用于等待 cloud-init 和并发压测。
- `TOPOLOGY`：TiUP topology 文件。
- `META_URL`：JuiceFS 使用的 TiKV metadata URL。
- `JFS_BUCKET`：RustFS S3 bucket URL。
- `SSH_USER` 和 `SSH_KEY`：登录 EC2 的用户和私钥。

## 5. 部署 TiKV 并初始化 JuiceFS

如果没有使用总控脚本，运行部署脚本：

```bash
scripts/run_aws_deploy.sh
```

这个脚本会执行：

- 等待 4 台机器 cloud-init 完成，并确认 JuiceFS 二进制已安装。
- 把 TiUP 安装脚本、TiKV 部署脚本、JuiceFS format 脚本、topology 和 SSH key 临时复制到 `CONTROL_HOST`。
- 在 VPC 内使用私网 IP 部署 `3 PD + 3 TiKV`。
- 使用 RustFS S3 API 初始化 JuiceFS。
- 退出时删除远端临时 key 和 env。

如果只想先等待节点初始化完成，可以单独执行：

```bash
scripts/wait_aws_nodes.sh
```

## 6. 运行亿级小文件 metadata test

执行 4 节点并发测试：

```bash
scripts/aws_full_deploy.sh test
```

也可以直接调用底层脚本：

```bash
scripts/run_metadata_test_all_nodes.sh
```

默认参数来自 `terraform/aws/generated/juicefs-aws.env`：

```bash
TARGET_FILES_PER_NODE=25000000
FILES_PER_DIR=100000
THREADS=256
DEPTH=2
WRITE_SIZE=1
```

`scripts/run_metadata_test.sh` 会根据 `FILES_PER_DIR`、`THREADS` 和 `DEPTH` 计算 JuiceFS `mdtest` 参数。由于目录树需要取整，默认配置每台实际估算约创建 `27,326,208` 个文件，4 台合计约 `109,304,832` 个文件，满足亿级小文件目标。

临时调小规模验证可以覆盖环境变量：

```bash
TARGET_FILES_PER_NODE=1000000 \
FILES_PER_DIR=10000 \
THREADS=64 \
scripts/run_metadata_test_all_nodes.sh
```

也可以追加 JuiceFS mdtest 参数：

```bash
EXTRA_MDTEST_ARGS="--rand" scripts/run_metadata_test_all_nodes.sh
```

## 7. 常用检查

在控制机查看 TiKV 集群：

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$CONTROL_HOST"
tiup cluster display "$CLUSTER_NAME"
tiup cluster status "$CLUSTER_NAME"
```

在任意节点查看 JuiceFS：

```bash
juicefs status "$META_URL"
juicefs info "$META_URL" /
```

RustFS service 在第 4 台节点上，默认 S3 API 监听 `9000`。RustFS console 端口 `9001` 默认不开放公网；只有设置 `expose_rustfs_console = true` 后才会对 `allowed_ssh_cidrs` 放行。

## 8. 清理资源

确认不再需要压测数据后销毁 AWS 资源：

```bash
CONFIRM_DESTROY=1 scripts/aws_full_deploy.sh destroy
```

默认仍会使用 `terraform destroy -auto-approve`；如果希望 Terraform 逐项确认：

```bash
CONFIRM_DESTROY=1 AUTO_APPROVE=0 scripts/aws_full_deploy.sh destroy
```

本地生成文件在 `.gitignore` 中已忽略，可按需删除：

```bash
rm -rf .terraform terraform.tfstate terraform.tfstate.backup generated/*
```

## 9. 排障

cloud-init 或二进制安装失败时，登录对应节点查看：

```bash
sudo tail -200 /var/log/cloud-init-output.log
sudo systemctl status rustfs
```

`scripts/run_aws_deploy.sh` 无法 SSH 时，优先检查：

- `allowed_ssh_cidrs` 是否包含当前公网出口。
- `SSH_KEY` 指向的私钥是否存在且权限正确。
- `SSH_USER` 是否匹配 AMI，默认 Ubuntu AMI 使用 `ubuntu`。
- 安全组是否允许 `22`、VPC 内是否允许 `2379`、`2380`、`20160`、`20180`、`9000`。

JuiceFS format 失败时，优先检查 RustFS：

- 第 4 台节点 `rustfs` systemd service 是否 running。
- `RUSTFS_ACCESS_KEY`、`RUSTFS_SECRET_KEY` 是否与 Terraform 配置一致。
- `RUSTFS_BUCKET` 是否已创建。
- `JFS_BUCKET` 是否形如 `http://<rustfs-private-ip>:9000/<bucket>`。

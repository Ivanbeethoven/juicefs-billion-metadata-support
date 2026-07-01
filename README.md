# JuiceFS + 3 TiKV + RustFS on AWS

这个仓库维护一套尽量二进制化、可自动落到 AWS 的 JuiceFS 部署和压测方案。

目标架构：

```text
3 x EC2: PD + TiKV + JuiceFS client
1 x EC2: RustFS + JuiceFS client

JuiceFS metadata -> TiKV
JuiceFS objects  -> RustFS S3 API
```

默认配置偏省钱验证：`m6i.xlarge`、gp3 默认性能、百万级小文件目标。需要亿级小文件压测时，使用 `DEPLOY_PROFILE=stress` 切到高配档。

完整步骤和架构图见 [AWS deployment steps](docs/aws-deployment-steps.md)。

## Quick Start

准备 AWS credential 和 Terraform 后，在仓库根目录执行：

```bash
scripts/aws_full_deploy.sh deploy
```

这个入口会自动完成机器创建、cloud-init、TiKV 部署和 JuiceFS 初始化：

- 生成 `terraform/aws/terraform.tfvars`
- 自动探测当前公网 IP 并写入 SSH allowlist
- 生成 RustFS 随机密钥
- 执行 `terraform init/apply`
- 等待 4 台 EC2 完成 cloud-init
- 在 VPC 内部署 `3 PD + 3 TiKV`
- 初始化 JuiceFS，metadata 使用 TiKV，object storage 使用 RustFS

如果只想先把 4 台 EC2 建好并完成 cloud-init，不部署 TiKV、不 format JuiceFS：

```bash
scripts/aws_full_deploy.sh provision
```

`provision` 会停在“机器已可 SSH、基础软件和 RustFS 节点 bootstrap 完成”的状态，后续再执行完整部署：

```bash
SKIP_TERRAFORM=1 scripts/aws_full_deploy.sh deploy
```

部署完成后运行 metadata test：

```bash
scripts/aws_full_deploy.sh test
```

运行真实小文件写入测试并生成 Markdown 报告：

```bash
scripts/aws_full_deploy.sh write-test
```

报告默认输出到：

```text
reports/file-write-<timestamp>/summary.md
```

销毁 AWS 资源需要显式确认：

```bash
CONFIRM_DESTROY=1 scripts/aws_full_deploy.sh destroy
```

如果希望 Terraform 在销毁前交互确认：

```bash
CONFIRM_DESTROY=1 AUTO_APPROVE=0 scripts/aws_full_deploy.sh destroy
```

## Configuration

默认配置文件由脚本生成：

```bash
scripts/aws/generate_aws_tfvars.sh
```

常用覆盖参数：

```bash
AWS_REGION=us-west-2 \
PROJECT_NAME=juicefs-prod \
ALLOWED_SSH_CIDRS="203.0.113.10/32" \
TIKV_INSTANCE_TYPE=i4i.2xlarge \
RUSTFS_INSTANCE_TYPE=i4i.2xlarge \
scripts/aws_full_deploy.sh deploy
```

## Deployment Profiles

默认 `DEPLOY_PROFILE=dev`，用于先跑通部署和百万级小文件验证：

```hcl
tikv_instance_type       = "m6i.xlarge" # 4 vCPU / 16 GiB
rustfs_instance_type     = "m6i.xlarge" # 4 vCPU / 16 GiB
tikv_data_volume_size_gb = 512
rustfs_data_volume_size_gb = 1024
data_volume_iops        = 3000
data_volume_throughput  = 125
target_total_files      = 1000000
files_per_dir           = 10000
test_threads            = 64
```

亿级压测使用 `DEPLOY_PROFILE=stress`：

```bash
DEPLOY_PROFILE=stress scripts/aws_full_deploy.sh deploy
```

`stress` 档会生成：

```hcl
tikv_instance_type       = "m6i.2xlarge" # 8 vCPU / 32 GiB
rustfs_instance_type     = "m6i.2xlarge" # 8 vCPU / 32 GiB
tikv_data_volume_size_gb = 2048
rustfs_data_volume_size_gb = 4096
data_volume_iops        = 12000
data_volume_throughput  = 500
target_total_files      = 100000000
files_per_dir           = 100000
test_threads            = 256
```

## Test File Counts

有两类测试，文件数量都可以配置。

Metadata test 使用 JuiceFS `mdtest`，主要压 metadata 路径：

```bash
# 总目标文件数，脚本按 JUICEFS_TEST_HOSTS 节点数自动平分
TARGET_TOTAL_FILES=100000000 scripts/aws_full_deploy.sh test

# 或者直接指定每台节点目标文件数
TARGET_FILES_PER_NODE=25000000 scripts/aws_full_deploy.sh test
```

`dev` 档默认 `target_total_files = 1000000`；`stress` 档默认 `target_total_files = 100000000`，4 台节点时会生成 `TARGET_FILES_PER_NODE=25000000`。由于 `mdtest` 要按目录树取整，实际创建文件数可能略高于目标值。

真实写入测试通过 JuiceFS 挂载点创建小文件，并生成 Markdown 报告：

```bash
# 总目标文件数，脚本按 JUICEFS_TEST_HOSTS 节点数自动平分
FILE_WRITE_TOTAL_FILES=100000000 \
FILE_WRITE_SIZE_BYTES=1 \
FILE_WRITE_WORKERS=256 \
FILES_PER_DIR=100000 \
scripts/aws_full_deploy.sh write-test
```

也可以指定每台节点写入数量：

```bash
FILE_WRITE_TARGET_PER_NODE=25000000 scripts/aws_full_deploy.sh write-test
```

先小规模试跑可以这样：

```bash
TARGET_TOTAL_FILES=1000000 scripts/aws_full_deploy.sh test
FILE_WRITE_TOTAL_FILES=1000000 scripts/aws_full_deploy.sh write-test
```

只检查文件数量分配、不连接远端机器：

```bash
JUICEFS_TEST_HOSTS="host1 host2 host3 host4" \
META_URL=tikv://127.0.0.1:2379/jfs \
TARGET_TOTAL_FILES=100000000 \
DRY_RUN=1 \
scripts/test/run_metadata_test_all_nodes.sh

JUICEFS_TEST_HOSTS="host1 host2 host3 host4" \
FILE_WRITE_TOTAL_FILES=100000000 \
DRY_RUN=1 \
scripts/test/run_file_write_test_all_nodes.sh
```

## Repository Layout

```text
terraform/aws/                 AWS 4 节点基础设施
docs/
  aws-deployment-steps.md      AWS 端到端部署步骤和架构图
  juicefs-tikv-3node-binary-deploy.md
  operations.md
  references.md
examples/
  juicefs-3tikv.env.example
scripts/
  aws_full_deploy.sh           稳定主入口，转发到 scripts/aws/
  aws/                         AWS 自动化、tfvars、等待节点、VPC 内部署
  install/                     TiUP、JuiceFS、RustFS 二进制安装和 systemd
  cluster/                     TiKV 部署、RustFS bucket、JuiceFS format
  test/                        metadata test、小文件写入测试、报告生成
tiup/
  topology.3tikv.example.yaml
```

## Generated Files

Terraform 会生成：

- `tiup/topology.aws.generated.yaml`
- `terraform/aws/generated/juicefs-aws.env`
- `terraform/aws/generated/<project>.pem`，当 `create_key_pair=true`

这些文件以及 Terraform state、报告目录、私钥、下载包都已加入 `.gitignore`。

## Security Defaults

- SSH 默认只开放给 `allowed_ssh_cidrs`。
- `scripts/aws/generate_aws_tfvars.sh` 会自动探测当前公网 IP；探测失败时会要求显式设置 `ALLOWED_SSH_CIDRS`。
- RustFS console 默认不暴露公网，需显式设置 `expose_rustfs_console = true`。
- `rustfs_secret_key` 由脚本自动生成，至少 16 个 shell-safe 字符。
- `destroy` 必须设置 `CONFIRM_DESTROY=1`。

## Manual Deployment

非 AWS 或手工环境可参考 [完整三节点二进制部署](docs/juicefs-tikv-3node-binary-deploy.md)。

如果不用 Terraform，可以复制 [examples/juicefs-3tikv.env.example](examples/juicefs-3tikv.env.example) 为 `.env`，按实际 IP、RustFS endpoint 和密钥修改后执行对应分类脚本。

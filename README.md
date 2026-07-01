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
scripts/aws_full_deploy.sh deploy-existing
```

`provision` 完成后，连接配置和生成文件集中在：

```text
run/slayerfs-rustfs/
  juicefs-aws.env
  slayerfs-rustfs.pem
  topology.aws.generated.yaml
```

其中 `juicefs-aws.env` 会记录 `SSH_USER`、`SSH_KEY`、`CONTROL_HOST`、`JUICEFS_TEST_HOSTS`、`RUSTFS_ENDPOINT`、`META_URL` 等连接和部署信息。

如果 4 台机器已经在本机 SSH config 中配置成 `aws1`、`aws2`、`aws3`、`aws4`，可以跳过 Terraform 输出，直接生成后续部署需要的 env 和 TiUP topology：

```bash
scripts/aws_full_deploy.sh ssh-env
scripts/aws_full_deploy.sh bootstrap-existing
scripts/aws_full_deploy.sh deploy-existing
```

默认约定：

- `aws1`、`aws2`、`aws3` 部署 `PD + TiKV`
- `aws4` 部署/访问 RustFS
- 脚本会探测 4 台机器的内网 IP，生成 `run/slayerfs-rustfs/juicefs-aws.env`
- 如果节点上存在 `/data/rustfs1`，TiKV 默认使用 `/data/rustfs1/tikv`，JuiceFS cache 默认使用 `/data/rustfs2/juicefs-cache`
- 默认会生成 `run/slayerfs-rustfs/ssh-alias-deploy-key`，并把公钥追加到 4 台机器的 `authorized_keys`，让控制机 `aws1` 可以用内网 IP 部署 TiKV

如果 RustFS 密钥无法从 `aws4:/etc/default/rustfs` 读取，需要显式传入：

```bash
RUSTFS_SECRET_KEY='your-secret' scripts/aws_full_deploy.sh ssh-env
```

已有外部 RustFS 时，可以只把 4 台 SSH alias 机器作为 3 个 TiKV 节点和 4 个 JuiceFS client。例如：

```bash
SSH_HOSTS="vm008 vm009 vm010 vm011" \
TIKV_HOSTS="vm008 vm009 vm010" \
CONTROL_HOST=vm008 \
INSTALL_CONTROL_SSH_KEY=0 \
RUSTFS_ENDPOINT="http://<rustfs-endpoint>:9000" \
RUSTFS_ACCESS_KEY="<access-key>" \
RUSTFS_SECRET_KEY="<secret-key>" \
FORCE=1 \
scripts/aws_full_deploy.sh ssh-env

scripts/aws_full_deploy.sh bootstrap-existing
scripts/aws_full_deploy.sh deploy-existing
```

部署完成后运行 metadata test：

```bash
scripts/aws_full_deploy.sh test
```

运行真实小文件写入测试并生成 Markdown 报告：

```bash
scripts/aws_full_deploy.sh write-test
```

查看正在运行的小文件写入测试进度：

```bash
TEST_RUN_ID=20260701-010203 scripts/aws_full_deploy.sh write-progress
```

精确统计当前批次已写入文件数时加 `EXACT_COUNT=1`。它会扫描 JuiceFS 元数据，长压测期间建议 10-30 分钟看一次，不要高频轮询：

```bash
TEST_RUN_ID=20260701-010203 \
EXACT_COUNT=1 \
scripts/aws_full_deploy.sh write-progress
```

测试完成后拉回远端结果并重建本地汇总：

```bash
TEST_RUN_ID=20260701-010203 scripts/aws_full_deploy.sh collect-write-results
```

报告默认输出到：

```text
reports/file-write/<run-id>/summary.md
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
PROJECT_NAME=slayerfs-rustfs \
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
tikv_raftstore_capacity = "" # auto: tikv data disk - 128GiB
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
tikv_raftstore_capacity = "" # auto: tikv data disk - 128GiB
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

两类测试都会生成聚合报告：

```text
reports/
  metadata/<run-id>/
    summary.md
    summary.kv
    hosts.tsv
    nodes/<host>/result.kv
    nodes/<host>/stdout.log
    nodes/<host>/stderr.log
    nodes/<host>/pre-node-info.log
    nodes/<host>/post-node-info.log
  file-write/<run-id>/
    summary.md
    summary.kv
    hosts.tsv
    nodes/<host>/result.kv
    nodes/<host>/stdout.log
    nodes/<host>/stderr.log
    nodes/<host>/pre-node-info.log
    nodes/<host>/post-node-info.log
```

`summary.md` 会聚合所有 JuiceFS 客户端的吞吐；`summary.kv` 适合脚本读取；每个 `nodes/<host>/` 目录保留远端 stdout/stderr、节点状态、`juicefs status`、`df`、进程和磁盘采样。默认也会采集 `iostat`，机器没有 `sysstat` 时会自动跳过。

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

优先级为：`FILE_WRITE_TARGET_PER_NODE` 强制单节点数量最高；未设置它时，`FILE_WRITE_TOTAL_FILES` 会按节点数自动平分；两者都未设置时才使用 env 中的 `TARGET_FILES_PER_NODE`。

写入测试目录前缀默认是 `filewrite`；如果要自定义，用 `FILE_WRITE_TEST_PREFIX=...`。metadata test 可用 `METADATA_TEST_PREFIX=...` 或 `TEST_PREFIX=...`。

如果测试中断，可以用同一个 `TEST_RUN_ID` 继续。metadata test 会跳过已成功的客户端，失败客户端会换 retry 目录重跑；file-write 会复用同名测试目录，跳过已存在且大小正确的文件，只补写缺失部分：

```bash
TEST_RUN_ID=20260701-010203 RESUME_TEST=1 scripts/aws_full_deploy.sh test
TEST_RUN_ID=20260701-010203 RESUME_TEST=1 scripts/aws_full_deploy.sh write-test
```

如果要复用已有报告目录，也可以显式指定：

```bash
REPORT_DIR=reports/file-write/20260701-010203 \
TEST_RUN_ID=20260701-010203 \
RESUME_TEST=1 \
scripts/aws_full_deploy.sh write-test
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

查看正在运行的 file-write 进度：

```bash
TEST_RUN_ID=20260701-010203 scripts/aws_full_deploy.sh write-progress
```

`write-progress` 会检查每个 JuiceFS 客户端上的远端 pid、进程状态、stderr 尾部、挂载点和 cache 目录容量。如果需要精确统计当前批次文件数，设置 `EXACT_COUNT=1`：

```bash
TEST_RUN_ID=20260701-010203 \
EXACT_COUNT=1 \
scripts/aws_full_deploy.sh write-progress
```

精确统计会执行 `find` 扫描 JuiceFS 目录，会额外压 metadata；长压测期间建议 10-30 分钟看一次即可。后端 RustFS 磁盘也可以一起采集：

```bash
TEST_RUN_ID=20260701-010203 \
RUSTFS_BACKEND_HOSTS="vm001 vm002 vm003" \
RUSTFS_BACKEND_JUMP_TARGET=juicefs-bastion \
scripts/aws_full_deploy.sh write-progress
```

远端 detached 运行或本地会话断开后，完成时用下面命令拉回结果并重建 `summary.md` / `summary.kv`：

```bash
TEST_RUN_ID=20260701-010203 scripts/aws_full_deploy.sh collect-write-results
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

- `run/<project>/topology.aws.generated.yaml`
- `run/<project>/juicefs-aws.env`
- `run/<project>/<project>.pem`，当 `create_key_pair=true`

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

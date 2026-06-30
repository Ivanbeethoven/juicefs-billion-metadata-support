# JuiceFS + 3 TiKV + RustFS on AWS

这个仓库维护一套尽量二进制化、可自动落到 AWS 的 JuiceFS 部署和压测方案。

目标架构：

```text
3 x EC2: PD + TiKV + JuiceFS client
1 x EC2: RustFS + JuiceFS client

JuiceFS metadata -> TiKV
JuiceFS objects  -> RustFS S3 API
```

默认压测目标是亿级小文件：`100,000,000` 个文件分散到 4 台 JuiceFS client 并发执行。部署完成后可以运行 metadata test，也可以通过挂载点真实写入大量小文件并生成测试报告。

完整步骤和架构图见 [AWS deployment steps](docs/aws-deployment-steps.md)。

## Quick Start

准备 AWS credential 和 Terraform 后，在仓库根目录执行：

```bash
scripts/aws_full_deploy.sh deploy
```

这个入口会自动完成：

- 生成 `terraform/aws/terraform.tfvars`
- 自动探测当前公网 IP 并写入 SSH allowlist
- 生成 RustFS 随机密钥
- 执行 `terraform init/apply`
- 等待 4 台 EC2 完成 cloud-init
- 在 VPC 内部署 `3 PD + 3 TiKV`
- 初始化 JuiceFS，metadata 使用 TiKV，object storage 使用 RustFS

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

默认压测参数：

```hcl
target_total_files = 100000000
files_per_dir      = 100000
test_threads       = 256
```

真实写入测试常用参数：

```bash
FILE_WRITE_TARGET_PER_NODE=25000000 \
FILE_WRITE_SIZE_BYTES=1 \
FILE_WRITE_WORKERS=256 \
FILES_PER_DIR=100000 \
scripts/aws_full_deploy.sh write-test
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

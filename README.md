# JuiceFS + 3 TiKV + RustFS on AWS

这个仓库维护一个可直接落到 AWS 的二进制部署骨架：

```text
3 x PD + TiKV + JuiceFS client
1 x RustFS + JuiceFS client

JuiceFS metadata -> TiKV
JuiceFS objects  -> RustFS S3 API
```

目标是用 4 台 EC2 跑通小规模生产/PoC，并提供亿级小文件 metadata test 的入口。默认目标是 `100,000,000` 个小文件，拆成 4 台客户端并发执行，每台约 `25,000,000` 个文件。

## 仓库内容

```text
terraform/aws/                     AWS 4 节点基础设施
docs/
  aws-deployment-steps.md
  juicefs-tikv-3node-binary-deploy.md
  operations.md
  references.md
examples/
  juicefs-3tikv.env.example
scripts/
  aws_full_deploy.sh               AWS 全自动部署总控脚本
  generate_aws_tfvars.sh           生成 terraform.tfvars 和随机密钥
  install_tiup_binary.sh           安装 TiUP/TiKV 二进制包
  deploy_3tikv_cluster.sh          部署 3 PD + 3 TiKV
  install_juicefs_binary.sh        安装 JuiceFS 二进制
  install_rustfs_binary.sh         安装 RustFS 二进制
  install_rustfs_service.sh        安装 RustFS systemd 服务
  create_rustfs_bucket.sh          创建 RustFS bucket
  format_juicefs.sh                初始化 JuiceFS
  run_aws_deploy.sh                在 AWS VPC 内部署 TiKV 并 format JuiceFS
  run_metadata_test_all_nodes.sh   4 节点并发 metadata test
tiup/
  topology.3tikv.example.yaml
```

## AWS 快速流程

完整逐步部署说明见 [AWS deployment steps](docs/aws-deployment-steps.md)。

```bash
scripts/aws_full_deploy.sh deploy
```

这个命令会自动生成 `terraform.tfvars`、执行 Terraform、等待节点初始化、部署 TiKV，并初始化 JuiceFS。metadata test 默认不会自动启动，需要确认资源规格和成本后执行：

```bash
scripts/aws_full_deploy.sh test
```

如果要部署后立刻跑 metadata test：

```bash
RUN_METADATA_TEST=1 scripts/aws_full_deploy.sh deploy
```

销毁 AWS 资源需要显式确认：

```bash
CONFIRM_DESTROY=1 scripts/aws_full_deploy.sh destroy
```

Terraform 会生成：

- `tiup/topology.aws.generated.yaml`
- `terraform/aws/generated/juicefs-aws.env`
- `terraform/aws/generated/<project>.pem`，当 `create_key_pair=true`

加载环境变量：

```bash
set -a
. terraform/aws/generated/juicefs-aws.env
set +a
```

等待 4 台机器 cloud-init 完成，部署 TiKV，并初始化 JuiceFS：

```bash
scripts/run_aws_deploy.sh
```

运行 4 节点 metadata test：

```bash
scripts/run_metadata_test_all_nodes.sh
```

默认压测参数在 `terraform.tfvars` 中配置：

```hcl
target_total_files = 100000000
files_per_dir      = 100000
test_threads       = 256
```

## 安全默认

- Terraform 默认不开放 SSH，必须在 `allowed_ssh_cidrs` 填你的办公网/VPN CIDR。
- `scripts/generate_aws_tfvars.sh` 会自动探测当前公网 IP 并生成 `/32`，也可以用 `ALLOWED_SSH_CIDRS` 覆盖。
- RustFS console 默认不暴露公网，需显式设置 `expose_rustfs_console = true`。
- `rustfs_secret_key` 会由脚本自动生成，至少 16 个 shell-safe 字符。
- 生成的私钥、env、state、下载包都已加入 `.gitignore`。

## 手工/非 AWS 流程

手工部署仍可使用 [完整三节点二进制部署](docs/juicefs-tikv-3node-binary-deploy.md)。如果不用 Terraform，复制 [examples/juicefs-3tikv.env.example](examples/juicefs-3tikv.env.example) 为 `.env`，按实际 IP、RustFS endpoint 和密钥修改即可。

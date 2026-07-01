#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform/aws}"
TFVARS_FILE="${TFVARS_FILE:-${TF_DIR}/terraform.tfvars}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
ACTION="${1:-deploy}"

usage() {
  cat <<'EOF'
Usage:
  scripts/aws_full_deploy.sh [provision|ssh-env|bootstrap-existing|deploy|deploy-existing|test|write-test|write-progress|collect-write-results|destroy|output]

Actions:
  provision
           Generate terraform.tfvars when missing, run terraform init/apply,
           and wait for EC2 cloud-init bootstrap to finish.
  ssh-env  Generate run/<project>/juicefs-aws.env and TiUP topology from
           SSH aliases. Default aliases: aws1 aws2 aws3 aws4.
  bootstrap-existing
           Prepare existing SSH hosts: packages, JuiceFS binary, TiKV user
           and data directories. Does not install RustFS.
  deploy   Generate terraform.tfvars when missing, run terraform init/apply,
           deploy TiKV, format JuiceFS, and install mount services.
  deploy-existing
           Reuse an existing env file and deploy TiKV/JuiceFS/mount services,
           without Terraform.
  test     Load generated env and run distributed JuiceFS metadata test.
  write-test
           Load generated env, write many small files through mounted JuiceFS,
           and generate a Markdown report under reports/.
  write-progress
           Check a running file write test: remote pids, stderr tails, df,
           optional exact file count, and optional RustFS backend disk usage.
  collect-write-results
           Pull completed remote file write results and generate a local
           summary report. Safe to run while jobs are still pending.
  destroy  Destroy AWS resources with terraform destroy.
  output   Show terraform outputs.

Common environment overrides:
  AWS_REGION=us-west-2
  PROJECT_NAME=slayerfs-rustfs
  ALLOWED_SSH_CIDRS="203.0.113.10/32,198.51.100.20/32"
  TIKV_INSTANCE_TYPE=i4i.2xlarge
  RUSTFS_INSTANCE_TYPE=i4i.2xlarge
  TARGET_TOTAL_FILES=100000000
  FILES_PER_DIR=100000
  TEST_THREADS=256
  DEPLOY_PROFILE=stress
  SSH_HOSTS="aws1 aws2 aws3 aws4"
  TEST_RUN_ID=20260701-010203
  RESUME_TEST=1
  REPORT_DIR=reports/file-write/20260701-010203
  COLLECT_NODE_INFO=1
  EXACT_COUNT=1
  RUSTFS_BACKEND_HOSTS="vm001 vm002 vm003"
  RUSTFS_BACKEND_JUMP_TARGET=juicefs-bastion

Safety switches:
  AUTO_APPROVE=0      Prompt during terraform apply/destroy. Default: 1.
  CONFIRM_DESTROY=1   Required for destroy action.
  FORCE_TFVARS=1      Regenerate terraform.tfvars even when it exists.
  RUN_METADATA_TEST=1 Run metadata test after deploy. Default: 0.
  SKIP_TERRAFORM=1    Reuse existing terraform outputs/env.
  SKIP_DEPLOY=1       Only create/update AWS resources.
  SKIP_WAIT=1         Do not wait for cloud-init in deploy-existing.
  SKIP_MOUNT=1        Do not install JuiceFS mount services.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

terraform_cmd() {
  "$TERRAFORM_BIN" -chdir="$TF_DIR" "$@"
}

tfvars_args() {
  default_tfvars="${TF_DIR}/terraform.tfvars"
  if [ "$(cd "$(dirname "$TFVARS_FILE")" && pwd)/$(basename "$TFVARS_FILE")" != "$(cd "$(dirname "$default_tfvars")" && pwd)/$(basename "$default_tfvars")" ]; then
    printf '%s\n' "-var-file=${TFVARS_FILE}"
  fi
}

load_env() {
  [ -f "$ENV_FILE" ] || die "generated env not found: ${ENV_FILE}"
  override_vars=(
    TARGET_TOTAL_FILES TARGET_FILES_PER_NODE FILES_PER_DIR THREADS TEST_THREADS
    WRITE_SIZE DEPTH MDTEST_DIRS EXTRA_MDTEST_ARGS TEST_RUN_ID REPORT_ROOT
    REPORT_DIR RESUME_TEST COLLECT_NODE_INFO DRY_RUN METADATA_TEST_PREFIX
    FILE_WRITE_TEST_PREFIX FILE_WRITE_TOTAL_FILES FILE_WRITE_TARGET_PER_NODE
    FILE_WRITE_SIZE_BYTES FILE_WRITE_WORKERS FILE_WRITE_MAX_SECONDS
    FILE_WRITE_SYNC_EVERY TEST_PREFIX MOUNT_POINT
  )
  for var in "${override_vars[@]}"; do
    if [ "${!var+x}" ]; then
      printf -v "__override_${var}" '%s' "${!var}"
      printf -v "__override_set_${var}" '1'
    fi
  done

  set -a
  . "$ENV_FILE"
  set +a

  for var in "${override_vars[@]}"; do
    set_var="__override_set_${var}"
    if [ "${!set_var:-}" = "1" ]; then
      value_var="__override_${var}"
      printf -v "$var" '%s' "${!value_var}"
      export "$var"
    fi
  done
}

generate_tfvars_if_needed() {
  if [ -f "$TFVARS_FILE" ] && [ "${FORCE_TFVARS:-0}" != "1" ]; then
    log "reuse existing ${TFVARS_FILE}"
    return 0
  fi

  log "generate ${TFVARS_FILE}"
  FORCE="${FORCE_TFVARS:-0}" OUT_FILE="$TFVARS_FILE" "${SCRIPT_DIR}/generate_aws_tfvars.sh"
}

terraform_apply() {
  need_cmd "$TERRAFORM_BIN"
  var_args=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && var_args+=("$arg")
  done < <(tfvars_args)

  log "terraform init"
  terraform_cmd init -input=false

  if [ "${AUTO_APPROVE:-1}" = "1" ]; then
    log "terraform apply -auto-approve"
    terraform_cmd apply "${var_args[@]}" -auto-approve
  else
    log "terraform apply"
    terraform_cmd apply "${var_args[@]}"
  fi
}

terraform_destroy() {
  if [ "${CONFIRM_DESTROY:-0}" != "1" ]; then
    die "destroy requires CONFIRM_DESTROY=1"
  fi

  need_cmd "$TERRAFORM_BIN"
  var_args=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && var_args+=("$arg")
  done < <(tfvars_args)

  log "terraform init"
  terraform_cmd init -input=false

  if [ "${AUTO_APPROVE:-1}" = "1" ]; then
    log "terraform destroy -auto-approve"
    terraform_cmd destroy "${var_args[@]}" -auto-approve
  else
    log "terraform destroy"
    terraform_cmd destroy "${var_args[@]}"
  fi
}

deploy_cluster() {
  load_env
  log "deploy TiKV cluster, format JuiceFS, and install mount services"
  ENV_FILE="$ENV_FILE" "${SCRIPT_DIR}/run_aws_deploy.sh"
}

wait_cloud_init() {
  load_env
  log "wait for EC2 cloud-init bootstrap"
  "${SCRIPT_DIR}/wait_aws_nodes.sh"
}

run_metadata_test() {
  load_env
  log "run distributed metadata test"
  "${REPO_ROOT}/scripts/test/run_metadata_test_all_nodes.sh"
}

run_file_write_test() {
  load_env
  log "run distributed file write test"
  "${REPO_ROOT}/scripts/test/run_file_write_test_all_nodes.sh"
}

run_file_write_progress() {
  load_env
  log "check distributed file write progress"
  "${REPO_ROOT}/scripts/test/check_file_write_progress.sh"
}

collect_file_write_results() {
  load_env
  log "collect distributed file write results"
  "${REPO_ROOT}/scripts/test/collect_file_write_results.sh"
}

case "$ACTION" in
  -h|--help|help)
    usage
    ;;
  provision)
    need_cmd curl
    generate_tfvars_if_needed
    if [ "${SKIP_TERRAFORM:-0}" != "1" ]; then
      terraform_apply
    else
      log "skip terraform apply"
    fi
    wait_cloud_init
    log "machines are ready; TiKV/JuiceFS deployment not started"
    ;;
  ssh-env)
    "${SCRIPT_DIR}/generate_ssh_alias_env.sh"
    ;;
  bootstrap-existing)
    load_env
    log "bootstrap existing SSH hosts"
    ENV_FILE="$ENV_FILE" "${SCRIPT_DIR}/bootstrap_existing_nodes.sh"
    ;;
  deploy)
    need_cmd curl
    generate_tfvars_if_needed
    if [ "${SKIP_TERRAFORM:-0}" != "1" ]; then
      terraform_apply
    else
      log "skip terraform apply"
    fi

    if [ "${SKIP_DEPLOY:-0}" != "1" ]; then
      deploy_cluster
    else
      log "skip TiKV/JuiceFS deployment"
    fi

    if [ "${RUN_METADATA_TEST:-0}" = "1" ]; then
      run_metadata_test
    else
      log "metadata test skipped; run scripts/aws_full_deploy.sh test when ready"
    fi
    ;;
  deploy-existing)
    deploy_cluster
    ;;
  test)
    run_metadata_test
    ;;
  write-test)
    run_file_write_test
    ;;
  write-progress)
    run_file_write_progress
    ;;
  collect-write-results)
    collect_file_write_results
    ;;
  destroy)
    terraform_destroy
    ;;
  output)
    need_cmd "$TERRAFORM_BIN"
    terraform_cmd output
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform/aws}"
TFVARS_FILE="${TFVARS_FILE:-${TF_DIR}/terraform.tfvars}"
ENV_FILE="${ENV_FILE:-${TF_DIR}/generated/juicefs-aws.env}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
ACTION="${1:-deploy}"

usage() {
  cat <<'EOF'
Usage:
  scripts/aws_full_deploy.sh [deploy|test|write-test|destroy|output]

Actions:
  deploy   Generate terraform.tfvars when missing, run terraform init/apply,
           deploy TiKV inside the VPC, and format JuiceFS.
  test     Load generated env and run distributed JuiceFS metadata test.
  write-test
           Load generated env, write many small files through mounted JuiceFS,
           and generate a Markdown report under reports/.
  destroy  Destroy AWS resources with terraform destroy.
  output   Show terraform outputs.

Common environment overrides:
  AWS_REGION=us-west-2
  PROJECT_NAME=juicefs-prod
  ALLOWED_SSH_CIDRS="203.0.113.10/32,198.51.100.20/32"
  TIKV_INSTANCE_TYPE=i4i.2xlarge
  RUSTFS_INSTANCE_TYPE=i4i.2xlarge
  TARGET_TOTAL_FILES=100000000
  FILES_PER_DIR=100000
  TEST_THREADS=256

Safety switches:
  AUTO_APPROVE=0      Prompt during terraform apply/destroy. Default: 1.
  CONFIRM_DESTROY=1   Required for destroy action.
  FORCE_TFVARS=1      Regenerate terraform.tfvars even when it exists.
  RUN_METADATA_TEST=1 Run metadata test after deploy. Default: 0.
  SKIP_TERRAFORM=1    Reuse existing terraform outputs/env.
  SKIP_DEPLOY=1       Only create/update AWS resources.
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
  set -a
  . "$ENV_FILE"
  set +a
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
  log "deploy TiKV cluster and format JuiceFS"
  ENV_FILE="$ENV_FILE" "${SCRIPT_DIR}/run_aws_deploy.sh"
}

run_metadata_test() {
  load_env
  log "run distributed metadata test"
  "${SCRIPT_DIR}/run_metadata_test_all_nodes.sh"
}

run_file_write_test() {
  load_env
  log "run distributed file write test"
  "${SCRIPT_DIR}/run_file_write_test_all_nodes.sh"
}

case "$ACTION" in
  -h|--help|help)
    usage
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
  test)
    run_metadata_test
    ;;
  write-test)
    run_file_write_test
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

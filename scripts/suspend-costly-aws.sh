#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-help}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${ROOT_DIR}"}
TARGET_TERRAFORM_DIR=${TARGET_TERRAFORM_DIR:-"${WORKSPACE_DIR}/target-hosts-setup"}
KUBERNETES_DIR=${KUBERNETES_DIR:-"${WORKSPACE_DIR}/kubernetes"}

AWS_REGION=${AWS_REGION:-ap-southeast-1}
ENVIRONMENT=${ENVIRONMENT:-dev}
PROJECT_NAME=${PROJECT_NAME:-dendenmushi}
CLUSTER_NAME=${CLUSTER_NAME:-"${PROJECT_NAME}-cluster-${ENVIRONMENT}"}
NODE_GROUP_NAME=${NODE_GROUP_NAME:-}
SSH_NAMESPACE=${SSH_NAMESPACE:-dendenmushi-ssh}
AGENTIC_NAMESPACE=${AGENTIC_NAMESPACE:-dendenmushi-agentic}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
LEGACY_NAMESPACE=${LEGACY_NAMESPACE:-dendenmushi}
APPLICATION_NAMESPACES=("${SSH_NAMESPACE}" "${AGENTIC_NAMESPACE}" "${WEBAPP_NAMESPACE}" "${LEGACY_NAMESPACE}")
APPLICATION_LB_NAME=${APPLICATION_LB_NAME:-"${PROJECT_NAME}-${ENVIRONMENT}"}
RDS_INSTANCE_ID=${RDS_INSTANCE_ID:-"${PROJECT_NAME}-postgres-${ENVIRONMENT}"}
ROUTE53_APPLICATION_RECORD_TARGET=${ROUTE53_APPLICATION_RECORD_TARGET:-"aws_route53_record.application[0]"}
PSQL_IMAGE=${PSQL_IMAGE:-postgres:16-alpine}

BACKUP_ROOT=${BACKUP_ROOT:-"${ROOT_DIR}/ignore/aws-cost-suspension"}
BACKUP_DIR=${BACKUP_DIR:-}
KUBECONFIG_FILE=${KUBECONFIG_FILE:-}

CONFIRM_DESTROY=${CONFIRM_DESTROY:-}
SKIP_DB_BACKUP=${SKIP_DB_BACKUP:-false}
CREATE_RDS_SNAPSHOT=${CREATE_RDS_SNAPSHOT:-false}
RESTORE_DB=${RESTORE_DB:-true}
DELETE_STUCK_ALB=${DELETE_STUCK_ALB:-true}
ALB_DELETE_TIMEOUT_SECONDS=${ALB_DELETE_TIMEOUT_SECONDS:-900}
ALB_POLL_SECONDS=${ALB_POLL_SECONDS:-30}
POST_INGRESS_DELETE_SLEEP_SECONDS=${POST_INGRESS_DELETE_SLEEP_SECONDS:-60}
POST_TERRAFORM_SLEEP_SECONDS=${POST_TERRAFORM_SLEEP_SECONDS:-30}
EXPECTED_AWS_ACCOUNT_ID=${EXPECTED_AWS_ACCOUNT_ID:-}
PUBLISH_GITOPS=${PUBLISH_GITOPS:-false}
GITOPS_REMOTE=${GITOPS_REMOTE:-origin}
GITOPS_BRANCH=${GITOPS_BRANCH:-main}
GITOPS_REPO_URL=${GITOPS_REPO_URL:-https://github.com/NUS-MTech-Capstone/kubernetes.git}
GITHUB_HOST=${GITHUB_HOST:-github.com}
ARGOCD_REPOSITORY_SECRET_NAME=${ARGOCD_REPOSITORY_SECRET_NAME:-dendenmushi-gitops-repository}
APPLICATION_DOMAIN_NAME=${APPLICATION_DOMAIN_NAME:-api.ddm.keiyam.me}
ALB_READY_TIMEOUT_SECONDS=${ALB_READY_TIMEOUT_SECONDS:-1800}
ARGOCD_READY_TIMEOUT_SECONDS=${ARGOCD_READY_TIMEOUT_SECONDS:-1800}
DNS_READY_TIMEOUT_SECONDS=${DNS_READY_TIMEOUT_SECONDS:-600}
RESTORE_POLL_SECONDS=${RESTORE_POLL_SECONDS:-15}

MAIN_TF_VAR_ARGS=()
for tfvars in "${AWS_TERRAFORM_DIR}/secrets.tfvars" "${AWS_TERRAFORM_DIR}/teammate-access.local.tfvars"; do
  if [[ -f "${tfvars}" ]]; then
    MAIN_TF_VAR_ARGS+=("-var-file=${tfvars}")
  fi
done

usage() {
  cat <<EOF
Usage:
  $(basename "$0") inventory
  $(basename "$0") backup
  CONFIRM_DESTROY=destroy-costly-aws $(basename "$0") down
  BACKUP_DIR=<backup-dir> $(basename "$0") restore-db
  BACKUP_DIR=<backup-dir> EXPECTED_AWS_ACCOUNT_ID=<account-id> \
    PUBLISH_GITOPS=true $(basename "$0") up
  $(basename "$0") verify-down

Actions:
  inventory   Capture Terraform, AWS, Kubernetes, ECR, Cognito, RDS, ALB, NAT,
              ENI, and target-host metadata into an ignored local backup dir.
  backup      Run inventory plus pg_dump backups for the webapp and incident
              PostgreSQL databases through a temporary Kubernetes psql pod.
  down        Backup first, then delete the application Route 53 alias record,
              delete Kubernetes ingresses and ALB, destroy target EC2, RDS,
              EKS, and NAT gateway/EIP. Hosted zones are never deleted.
  restore-db  Restore db-webapp.dump and db-incident.dump from BACKUP_DIR into
              the current Kubernetes/RDS environment.
  up          Recreate the platform using Terraform, target bootstrap,
              Kubernetes bootstrap, optional DB restore, verification, and the
              final application DNS apply.
  verify-down Check that the costly resources are absent.

Important env:
  BACKUP_DIR                        Use a specific backup dir for restore/up.
  BACKUP_ROOT=${BACKUP_ROOT}
  AWS_REGION=${AWS_REGION}
  SKIP_DB_BACKUP=false              Set true only if DB data is disposable.
  CREATE_RDS_SNAPSHOT=false         Optional manual RDS snapshot before destroy;
                                    this has snapshot storage cost.
  RESTORE_DB=true                   Used by up.
  EXPECTED_AWS_ACCOUNT_ID           Must match the backup and active AWS caller.
  PUBLISH_GITOPS=false              Must be true for up; publishes generated
                                    Kubernetes overlay values to GitHub.
  GITOPS_REMOTE=origin              Kubernetes Git remote used by up.
  GITOPS_BRANCH=main                Kubernetes branch used by Argo CD.
  GITOPS_REPO_URL=${GITOPS_REPO_URL}
                                    Private repository registered in Argo CD.
                                    Uses the existing gh login for GITHUB_HOST.
  DELETE_STUCK_ALB=true             Fallback to AWS ELBv2 delete if controller
                                    does not remove the ALB in time.
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

require_command() {
  local command=$1
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
}

require_common_commands() {
  for command in aws terraform kubectl jq date shasum; do
    require_command "${command}"
  done
}

require_up_commands() {
  require_common_commands
  for command in curl diff dig gh git tr; do
    require_command "${command}"
  done
}

backup_dir_for_write() {
  if [[ -z "${BACKUP_DIR}" ]]; then
    BACKUP_DIR="${BACKUP_ROOT}/$(date -u '+%Y%m%dT%H%M%SZ')"
  fi
  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
  if [[ -z "${KUBECONFIG_FILE}" ]]; then
    KUBECONFIG_FILE="${BACKUP_DIR}/kubeconfig"
  fi
  log "Using backup dir: ${BACKUP_DIR}"
}

latest_backup_dir() {
  local dir latest

  while IFS= read -r dir; do
    if [[ -f "${dir}/db-webapp.dump" && -f "${dir}/db-incident.dump" ]]; then
      printf '%s\n' "${dir}"
      return
    fi
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

  latest=$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1 || true)
  if [[ -z "${latest}" ]]; then
    echo "No backup dirs found under ${BACKUP_ROOT}" >&2
    exit 1
  fi
  printf '%s\n' "${latest}"
}

backup_dir_for_read() {
  if [[ -z "${BACKUP_DIR}" ]]; then
    BACKUP_DIR=$(latest_backup_dir)
  fi
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "BACKUP_DIR does not exist: ${BACKUP_DIR}" >&2
    exit 1
  fi
  if [[ -z "${KUBECONFIG_FILE}" ]]; then
    KUBECONFIG_FILE="${BACKUP_DIR}/kubeconfig"
  fi
  log "Using backup dir: ${BACKUP_DIR}"
}

assert_restore_account() {
  local identity_file backup_account actual_account actual_arn expected_account

  identity_file="${BACKUP_DIR}/aws-caller-identity.json"
  if [[ ! -f "${identity_file}" ]]; then
    echo "Backup AWS identity is missing: ${identity_file}" >&2
    exit 1
  fi

  backup_account=$(jq -r '.Account // empty' "${identity_file}")
  if [[ ! "${backup_account}" =~ ^[0-9]{12}$ ]]; then
    echo "Backup AWS account is invalid in ${identity_file}" >&2
    exit 1
  fi

  expected_account=${EXPECTED_AWS_ACCOUNT_ID:-${backup_account}}
  if [[ "${expected_account}" != "${backup_account}" ]]; then
    echo "EXPECTED_AWS_ACCOUNT_ID ${expected_account} does not match backup account ${backup_account}." >&2
    exit 1
  fi

  actual_account=$(aws sts get-caller-identity --query Account --output text)
  actual_arn=$(aws sts get-caller-identity --query Arn --output text)
  if [[ "${actual_account}" != "${expected_account}" ]]; then
    echo "Refusing restore: active AWS account ${actual_account} does not match expected account ${expected_account}." >&2
    exit 1
  fi

  EXPECTED_AWS_ACCOUNT_ID=${expected_account}
  log "Verified AWS account ${actual_account} (${actual_arn})."
}

aws_tf() {
  terraform -chdir="${AWS_TERRAFORM_DIR}" "$@"
}

target_tf() {
  terraform -chdir="${TARGET_TERRAFORM_DIR}" "$@"
}

kubectl_cmd() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" "$@"
}

cleanup_temp_psql_pods() {
  if [[ -n "${KUBECONFIG_FILE:-}" && -f "${KUBECONFIG_FILE}" ]]; then
    for namespace in "${APPLICATION_NAMESPACES[@]}"; do
      kubectl --kubeconfig "${KUBECONFIG_FILE}" \
        delete pod -n "${namespace}" -l app=ddm-cost-suspend-psql \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup_temp_psql_pods EXIT

init_terraform() {
  log "Initializing Terraform in aws-terraform"
  aws_tf init -reconfigure
  log "Initializing Terraform in target-hosts-setup"
  target_tf init -reconfigure
}

tf_output_raw() {
  local dir=$1
  local name=$2
  terraform -chdir="${dir}" output -raw "${name}" 2>/dev/null || true
}

detect_outputs() {
  local output
  output=$(tf_output_raw "${AWS_TERRAFORM_DIR}" cluster_name)
  if [[ -n "${output}" ]]; then
    CLUSTER_NAME="${output}"
  fi

  output=$(tf_output_raw "${AWS_TERRAFORM_DIR}" node_group_name)
  if [[ -n "${output}" ]]; then
    NODE_GROUP_NAME="${output}"
  fi
}

cluster_exists() {
  aws eks describe-cluster \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}" >/dev/null 2>&1
}

configure_kubectl() {
  if ! cluster_exists; then
    return 1
  fi
  mkdir -p "$(dirname "${KUBECONFIG_FILE}")"
  aws eks update-kubeconfig \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG_FILE}" >/dev/null
}

capture() {
  local output_file=$1
  shift

  log "Capture ${output_file#${BACKUP_DIR}/}"
  if "$@" >"${output_file}" 2>"${output_file}.stderr"; then
    rm -f "${output_file}.stderr"
  else
    log "Capture failed: ${output_file#${BACKUP_DIR}/}; see ${output_file}.stderr"
  fi
}

capture_inventory() {
  require_common_commands
  backup_dir_for_write
  init_terraform
  detect_outputs

  cat >"${BACKUP_DIR}/metadata.json" <<EOF
{
  "capturedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "awsRegion": "${AWS_REGION}",
  "environment": "${ENVIRONMENT}",
  "projectName": "${PROJECT_NAME}",
  "clusterName": "${CLUSTER_NAME}",
  "nodeGroupName": "${NODE_GROUP_NAME}",
  "namespaces": ["${SSH_NAMESPACE}", "${AGENTIC_NAMESPACE}", "${WEBAPP_NAMESPACE}"],
  "legacyNamespace": "${LEGACY_NAMESPACE}",
  "applicationLoadBalancerName": "${APPLICATION_LB_NAME}",
  "rdsInstanceId": "${RDS_INSTANCE_ID}",
  "route53HostedZonesDeleted": false
}
EOF

  capture "${BACKUP_DIR}/aws-caller-identity.json" aws sts get-caller-identity
  capture "${BACKUP_DIR}/main-terraform-outputs.json" aws_tf output -json
  capture "${BACKUP_DIR}/main-terraform-state-list.txt" aws_tf state list
  capture "${BACKUP_DIR}/target-terraform-outputs.json" target_tf output -json
  capture "${BACKUP_DIR}/target-terraform-state-list.txt" target_tf state list

  local vpc_id target_instance_id user_pool_id
  vpc_id=$(jq -r '.vpc_id.value // empty' "${BACKUP_DIR}/main-terraform-outputs.json" 2>/dev/null || true)
  target_instance_id=$(jq -r '.instance_id.value // empty' "${BACKUP_DIR}/target-terraform-outputs.json" 2>/dev/null || true)
  user_pool_id=$(jq -r '.cognito_user_pool_id.value // empty' "${BACKUP_DIR}/main-terraform-outputs.json" 2>/dev/null || true)

  capture "${BACKUP_DIR}/eks-cluster.json" \
    aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

  if [[ -n "${NODE_GROUP_NAME}" ]]; then
    capture "${BACKUP_DIR}/eks-nodegroup.json" \
      aws eks describe-nodegroup --region "${AWS_REGION}" --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODE_GROUP_NAME}"
  fi

  capture "${BACKUP_DIR}/alb.json" \
    aws elbv2 describe-load-balancers --region "${AWS_REGION}" --names "${APPLICATION_LB_NAME}"
  capture "${BACKUP_DIR}/rds.json" \
    aws rds describe-db-instances --region "${AWS_REGION}" --db-instance-identifier "${RDS_INSTANCE_ID}"

  if [[ -n "${vpc_id}" ]]; then
    capture "${BACKUP_DIR}/nat-gateways.json" \
      aws ec2 describe-nat-gateways --region "${AWS_REGION}" --filter "Name=vpc-id,Values=${vpc_id}"
    capture "${BACKUP_DIR}/network-interfaces.json" \
      aws ec2 describe-network-interfaces --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${vpc_id}"
    capture "${BACKUP_DIR}/security-groups.json" \
      aws ec2 describe-security-groups --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${vpc_id}"
  fi

  if [[ -n "${target_instance_id}" ]]; then
    capture "${BACKUP_DIR}/target-instance.json" \
      aws ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${target_instance_id}"
  fi

  if [[ -n "${user_pool_id}" ]]; then
    capture "${BACKUP_DIR}/cognito-users.json" \
      aws cognito-idp list-users --region "${AWS_REGION}" --user-pool-id "${user_pool_id}"
    capture "${BACKUP_DIR}/cognito-groups.json" \
      aws cognito-idp list-groups --region "${AWS_REGION}" --user-pool-id "${user_pool_id}"
  fi

  if jq -e '.ecr_repository_urls.value' "${BACKUP_DIR}/main-terraform-outputs.json" >/dev/null 2>&1; then
    mkdir -p "${BACKUP_DIR}/ecr"
    while IFS= read -r repository; do
      local safe_name
      safe_name=${repository//\//__}
      capture "${BACKUP_DIR}/ecr/${safe_name}.json" \
        aws ecr describe-images --region "${AWS_REGION}" --repository-name "${repository}"
    done < <(jq -r '.ecr_repository_urls.value | keys[]' "${BACKUP_DIR}/main-terraform-outputs.json")
  fi

  if configure_kubectl; then
    capture "${BACKUP_DIR}/k8s-namespaces.txt" kubectl_cmd get namespaces
    capture "${BACKUP_DIR}/k8s-pods-wide.txt" kubectl_cmd get pods -A -o wide
    capture "${BACKUP_DIR}/k8s-ingress-wide.txt" kubectl_cmd get ingress -A -o wide
    capture "${BACKUP_DIR}/k8s-services-wide.txt" kubectl_cmd get svc -A -o wide
    capture "${BACKUP_DIR}/k8s-pvc.txt" kubectl_cmd get pvc -A
    capture "${BACKUP_DIR}/k8s-applications.txt" kubectl_cmd get applications -A
    for namespace in "${APPLICATION_NAMESPACES[@]}"; do
      capture "${BACKUP_DIR}/k8s-${namespace}-configmaps.txt" kubectl_cmd get configmaps -n "${namespace}"
      capture "${BACKUP_DIR}/k8s-${namespace}-secrets-names.txt" kubectl_cmd get secrets -n "${namespace}"
      capture "${BACKUP_DIR}/k8s-${namespace}-workloads.yaml" kubectl_cmd get deploy,svc,ingress,configmap -n "${namespace}" -o yaml
    done
  else
    log "EKS cluster is not reachable; skipping Kubernetes inventory."
  fi
}

psql_pod_manifest() {
  local pod=$1
  local secret=$2
  jq -cn \
    --arg pod "${pod}" \
    --arg image "${PSQL_IMAGE}" \
    --arg secret "${secret}" \
    '{
      apiVersion: "v1",
      kind: "Pod",
      metadata: {name: $pod, labels: {app: "ddm-cost-suspend-psql", component: "database-maintenance"}},
      spec: {
        restartPolicy: "Never",
        securityContext: {seccompProfile: {type: "RuntimeDefault"}},
        containers: [{
          name: "postgres",
          image: $image,
          command: ["sleep", "7200"],
          securityContext: {
            allowPrivilegeEscalation: false,
            capabilities: {drop: ["ALL"]},
            runAsGroup: 70,
            runAsNonRoot: true,
            runAsUser: 70
          },
          resources: {
            requests: {cpu: "25m", memory: "64Mi"},
            limits: {cpu: "250m", memory: "256Mi"}
          },
          env: [{
            name: "DATABASE_URL",
            valueFrom: {secretKeyRef: {name: $secret, key: "database-url"}}
          }]
        }]
      }
    }'
}

start_psql_pod() {
  local label=$1
  local secret=$2
  local namespace=$3
  local pod="ddm-${label}-pg-$(date -u '+%H%M%S')"

  kubectl_cmd delete pod "${pod}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  psql_pod_manifest "${pod}" "${secret}" | kubectl_cmd apply -n "${namespace}" -f - >/dev/null
  kubectl_cmd wait --for=condition=Ready "pod/${pod}" -n "${namespace}" --timeout=180s >/dev/null
  printf '%s\n' "${pod}"
}

delete_psql_pod() {
  local pod=$1
  local namespace=$2
  kubectl_cmd delete pod "${pod}" -n "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

table_count_query() {
  cat <<'SQL'
select 'select ' ||
       quote_literal(n.nspname || '.' || c.relname) ||
       ' as table_name, count(*) as row_count from ' ||
       quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';'
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r'
  and n.nspname not in ('pg_catalog', 'information_schema')
order by n.nspname, c.relname
SQL
}

backup_database() {
  local label=$1
  local secret=$2
  local namespace=$3
  local pod
  local query
  query=$(table_count_query)

  log "Backing up PostgreSQL database ${label}"
  pod=$(start_psql_pod "${label}" "${secret}" "${namespace}")
  trap 'delete_psql_pod "${pod}" "${namespace}"' RETURN

  kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; pg_dump "$DATABASE_URL" --format=custom --no-owner --no-acl' \
    >"${BACKUP_DIR}/db-${label}.dump"

  kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    env TABLE_COUNT_QUERY="${query}" \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "$TABLE_COUNT_QUERY" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	"' \
    >"${BACKUP_DIR}/db-${label}-counts.tsv"

  kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "select current_database(), current_user, inet_server_addr(), inet_server_port();"' \
    >"${BACKUP_DIR}/db-${label}-connection.tsv"

  delete_psql_pod "${pod}" "${namespace}"
  trap - RETURN
}

backup_databases() {
  local webapp_namespace incident_namespace

  if [[ "${SKIP_DB_BACKUP}" == "true" ]]; then
    log "Skipping PostgreSQL backup because SKIP_DB_BACKUP=true."
    return
  fi
  if ! configure_kubectl; then
    echo "Cannot back up PostgreSQL because EKS is not reachable." >&2
    exit 1
  fi
  webapp_namespace=$(database_namespace_for_secret "dendenmushi-webapp-database" "${WEBAPP_NAMESPACE}")
  incident_namespace=$(database_namespace_for_secret "dendenmushi-database" "${AGENTIC_NAMESPACE}")
  backup_database "webapp" "dendenmushi-webapp-database" "${webapp_namespace}"
  backup_database "incident" "dendenmushi-database" "${incident_namespace}"
}

database_namespace_for_secret() {
  local secret=$1
  local preferred_namespace=$2

  if kubectl_cmd get secret "${secret}" -n "${preferred_namespace}" >/dev/null 2>&1; then
    printf '%s\n' "${preferred_namespace}"
    return
  fi
  if kubectl_cmd get secret "${secret}" -n "${LEGACY_NAMESPACE}" >/dev/null 2>&1; then
    printf '%s\n' "${LEGACY_NAMESPACE}"
    return
  fi

  echo "Secret ${secret} was not found in ${preferred_namespace} or ${LEGACY_NAMESPACE}." >&2
  exit 1
}

backup_all() {
  capture_inventory
  backup_databases
}

destroy_route53_application_record() {
  log "Deleting application Route 53 alias record only; hosted zones are not deleted."
  aws_tf destroy \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -target="${ROUTE53_APPLICATION_RECORD_TARGET}" || true
}

wait_for_alb_deleted() {
  local deadline
  deadline=$((SECONDS + ALB_DELETE_TIMEOUT_SECONDS))

  while aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --names "${APPLICATION_LB_NAME}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    log "Waiting for ALB ${APPLICATION_LB_NAME} to be deleted..."
    sleep "${ALB_POLL_SECONDS}"
  done

  return 0
}

delete_stuck_alb() {
  local alb_json arn target_groups
  alb_json=$(aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --names "${APPLICATION_LB_NAME}" 2>/dev/null || true)
  arn=$(jq -r '.LoadBalancers[0].LoadBalancerArn // empty' <<<"${alb_json}")
  if [[ -z "${arn}" ]]; then
    return 0
  fi

  log "Deleting stuck ALB ${APPLICATION_LB_NAME} directly through ELBv2."
  target_groups=$(aws elbv2 describe-target-groups \
    --region "${AWS_REGION}" \
    --load-balancer-arn "${arn}" \
    --query 'TargetGroups[].TargetGroupArn' \
    --output text 2>/dev/null || true)
  aws elbv2 delete-load-balancer --region "${AWS_REGION}" --load-balancer-arn "${arn}"
  aws elbv2 wait load-balancers-deleted --region "${AWS_REGION}" --load-balancer-arns "${arn}"

  for target_group in ${target_groups}; do
    aws elbv2 delete-target-group \
      --region "${AWS_REGION}" \
      --target-group-arn "${target_group}" >/dev/null 2>&1 || true
  done
}

delete_kubernetes_ingresses_and_alb() {
  if ! configure_kubectl; then
    log "EKS is not reachable; skipping Kubernetes ingress deletion."
    return
  fi

  log "Deleting Argo CD Application if present so GitOps does not recreate ingresses."
  kubectl_cmd delete application dendenmushi-dev \
    -n argocd \
    --ignore-not-found \
    --wait=false >/dev/null 2>&1 || true

  log "Deleting Kubernetes ingresses in all DenDenMushi namespaces so the ALB controller removes the ALB."
  kubectl_cmd get ingress --all-namespaces -l app=dendenmushi -o yaml >"${BACKUP_DIR}/k8s-ingresses-before-delete.yaml" 2>/dev/null || true
  for namespace in "${APPLICATION_NAMESPACES[@]}"; do
    if kubectl_cmd get namespace "${namespace}" >/dev/null 2>&1; then
      kubectl_cmd delete ingress --all -n "${namespace}" --ignore-not-found --wait=true
    fi
  done
  sleep "${POST_INGRESS_DELETE_SLEEP_SECONDS}"

  if wait_for_alb_deleted; then
    log "ALB ${APPLICATION_LB_NAME} was deleted by the controller."
    return
  fi

  if [[ "${DELETE_STUCK_ALB}" == "true" ]]; then
    delete_stuck_alb
  else
    echo "ALB ${APPLICATION_LB_NAME} still exists. Set DELETE_STUCK_ALB=true or delete it manually." >&2
    exit 1
  fi
}

destroy_target_hosts() {
  log "Destroying target-host stack."
  "${TARGET_TERRAFORM_DIR}/scripts/destroy.sh" -auto-approve
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"
}

create_optional_rds_snapshot() {
  if [[ "${CREATE_RDS_SNAPSHOT}" != "true" ]]; then
    return
  fi

  local snapshot_id
  snapshot_id="${RDS_INSTANCE_ID}-pre-suspend-$(date -u '+%Y%m%d%H%M%S')"
  log "Creating manual RDS snapshot ${snapshot_id}. Snapshot storage has monthly cost."
  aws rds create-db-snapshot \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --db-snapshot-identifier "${snapshot_id}" \
    >"${BACKUP_DIR}/rds-snapshot-create.json"
  aws rds wait db-snapshot-completed \
    --region "${AWS_REGION}" \
    --db-snapshot-identifier "${snapshot_id}"
  printf '%s\n' "${snapshot_id}" >"${BACKUP_DIR}/rds-snapshot-id.txt"
}

destroy_rds() {
  create_optional_rds_snapshot
  log "Destroying RDS instance and PostgreSQL security group from Terraform state."
  aws_tf destroy \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -target=aws_db_instance.postgres \
    -target=aws_security_group.postgres
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"
}

destroy_eks() {
  log "Destroying Kubernetes add-ons, Helm releases, and EKS cluster/node group."
  aws_tf destroy \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -target=helm_release.argocd \
    -target=helm_release.alb_controller \
    -target=helm_release.cert_manager \
    -target=kubernetes_role.teammate_access_argocd_port_forward \
    -target=kubernetes_role.teammate_access_database_shell \
    -target=kubernetes_role_binding.teammate_access_argocd_port_forward \
    -target=kubernetes_role_binding.teammate_access_database_shell \
    -target=kubernetes_service_account_v1.alb_controller \
    -target=kubernetes_namespace.argocd \
    -target=aws_eks_addon.cloudwatch_observability \
    -target=aws_eks_pod_identity_association.cloudwatch_agent \
    -target=aws_eks_addon.pod_identity_agent \
    -target=module.eks
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"
}

destroy_nat_gateway() {
  log "Destroying NAT route, NAT gateway, and NAT EIP. The VPC/subnets are left for low-cost restore."
  aws_tf destroy \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -target='module.vpc.aws_route.private_nat_gateway[0]' \
    -target='module.vpc.aws_nat_gateway.this[0]' \
    -target='module.vpc.aws_eip.nat[0]'
}

verify_down() {
  require_common_commands
  backup_dir_for_write
  init_terraform
  detect_outputs

  local status_file="${BACKUP_DIR}/verify-down.txt"
  : >"${status_file}"

  if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "EKS_PRESENT ${CLUSTER_NAME}" | tee -a "${status_file}"
  else
    echo "EKS_ABSENT ${CLUSTER_NAME}" | tee -a "${status_file}"
  fi

  if aws rds describe-db-instances --region "${AWS_REGION}" --db-instance-identifier "${RDS_INSTANCE_ID}" >/dev/null 2>&1; then
    echo "RDS_PRESENT ${RDS_INSTANCE_ID}" | tee -a "${status_file}"
  else
    echo "RDS_ABSENT ${RDS_INSTANCE_ID}" | tee -a "${status_file}"
  fi

  if aws elbv2 describe-load-balancers --region "${AWS_REGION}" --names "${APPLICATION_LB_NAME}" >/dev/null 2>&1; then
    echo "ALB_PRESENT ${APPLICATION_LB_NAME}" | tee -a "${status_file}"
  else
    echo "ALB_ABSENT ${APPLICATION_LB_NAME}" | tee -a "${status_file}"
  fi

  local vpc_id
  vpc_id=$(tf_output_raw "${AWS_TERRAFORM_DIR}" vpc_id)
  if [[ -n "${vpc_id}" ]]; then
    aws ec2 describe-nat-gateways \
      --region "${AWS_REGION}" \
      --filter "Name=vpc-id,Values=${vpc_id}" \
      --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' \
      --output text \
      >"${BACKUP_DIR}/verify-down-nat.txt" || true
    if [[ -s "${BACKUP_DIR}/verify-down-nat.txt" ]]; then
      sed 's/^/NAT_PRESENT /' "${BACKUP_DIR}/verify-down-nat.txt" | tee -a "${status_file}"
    else
      echo "NAT_ABSENT ${vpc_id}" | tee -a "${status_file}"
    fi
  fi
}

down() {
  if [[ "${CONFIRM_DESTROY}" != "destroy-costly-aws" ]]; then
    echo "Refusing destructive teardown. Re-run with CONFIRM_DESTROY=destroy-costly-aws." >&2
    exit 1
  fi

  backup_all
  destroy_route53_application_record
  delete_kubernetes_ingresses_and_alb
  destroy_target_hosts
  destroy_rds
  destroy_eks
  destroy_nat_gateway
  verify_down
  log "Costly AWS resource teardown completed. Backup dir: ${BACKUP_DIR}"
  exit 0
}

restore_database() {
  local label=$1
  local secret=$2
  local namespace=$3
  local dump_file="${BACKUP_DIR}/db-${label}.dump"
  local pod query expected_sha actual_sha

  if [[ ! -f "${dump_file}" ]]; then
    log "No dump found for ${label}: ${dump_file}; skipping."
    return
  fi

  log "Restoring PostgreSQL database ${label}"
  query=$(table_count_query)
  pod=$(start_psql_pod "${label}-restore" "${secret}" "${namespace}")
  trap 'delete_psql_pod "${pod}" "${namespace}"' RETURN

  expected_sha=$(shasum -a 256 "${dump_file}" | awk '{print $1}')
  kubectl_cmd cp "${dump_file}" "${namespace}/${pod}:/tmp/${label}.dump" -c postgres
  actual_sha=$(kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    sh -c "sha256sum /tmp/${label}.dump | cut -d ' ' -f 1")
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "Transferred ${label} dump checksum does not match the backup." >&2
    exit 1
  fi
  kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    sh -c "DATABASE_URL=\$(printf \"%s\" \"\$DATABASE_URL\" | sed \"s/sslmode=no-verify/sslmode=require/g\"); export DATABASE_URL; pg_restore --clean --if-exists --no-owner --no-acl --dbname \"\$DATABASE_URL\" /tmp/${label}.dump"
  kubectl_cmd exec "${pod}" -n "${namespace}" -c postgres -- \
    env TABLE_COUNT_QUERY="${query}" \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "$TABLE_COUNT_QUERY" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	"' \
    >"${BACKUP_DIR}/db-${label}-counts-after-restore.tsv"

  delete_psql_pod "${pod}" "${namespace}"
  trap - RETURN
}

restore_databases() {
  local webapp_namespace incident_namespace

  require_common_commands
  backup_dir_for_read
  if ! configure_kubectl; then
    echo "Cannot restore PostgreSQL because EKS is not reachable." >&2
    exit 1
  fi

  webapp_namespace=$(database_namespace_for_secret "dendenmushi-webapp-database" "${WEBAPP_NAMESPACE}")
  incident_namespace=$(database_namespace_for_secret "dendenmushi-database" "${AGENTIC_NAMESPACE}")
  restore_database "webapp" "dendenmushi-webapp-database" "${webapp_namespace}"
  restore_database "incident" "dendenmushi-database" "${incident_namespace}"

  for deployment in session-manager audit-service; do
    kubectl_cmd rollout restart "deployment/${deployment}" -n "${SSH_NAMESPACE}" >/dev/null 2>&1 || true
  done
  for deployment in agent-controlplane incident-agent incident-reasoning-agent agent-tool-gateway; do
    kubectl_cmd rollout restart "deployment/${deployment}" -n "${AGENTIC_NAMESPACE}" >/dev/null 2>&1 || true
  done
  kubectl_cmd rollout restart deployment/nest-backend -n "${WEBAPP_NAMESPACE}" >/dev/null 2>&1 || true
}

verify_database_counts() {
  local label expected actual

  for label in webapp incident; do
    expected="${BACKUP_DIR}/db-${label}-counts.tsv"
    actual="${BACKUP_DIR}/db-${label}-counts-after-restore.tsv"
    if [[ ! -f "${expected}" || ! -f "${actual}" ]]; then
      echo "Cannot verify restored ${label} counts; expected ${expected} and ${actual}." >&2
      exit 1
    fi
    if ! diff -u "${expected}" "${actual}"; then
      echo "Restored ${label} table counts do not match the backup." >&2
      exit 1
    fi
  done

  log "Restored PostgreSQL table counts match both backups."
}

gitops_git() {
  git -C "${KUBERNETES_DIR}" "$@"
}

require_gitops_publish_ready() {
  local branch local_head remote_head

  if [[ "${PUBLISH_GITOPS}" != "true" ]]; then
    echo "Restore requires PUBLISH_GITOPS=true so Argo CD receives regenerated AWS and target values." >&2
    exit 1
  fi

  branch=$(gitops_git branch --show-current)
  if [[ "${branch}" != "${GITOPS_BRANCH}" ]]; then
    echo "Kubernetes repository is on ${branch}; expected ${GITOPS_BRANCH}." >&2
    exit 1
  fi
  if [[ -n "$(gitops_git status --porcelain --untracked-files=all)" ]]; then
    echo "Kubernetes repository must be clean before restore." >&2
    gitops_git status --short >&2
    exit 1
  fi

  gitops_git fetch "${GITOPS_REMOTE}" "${GITOPS_BRANCH}"
  local_head=$(gitops_git rev-parse HEAD)
  remote_head=$(gitops_git rev-parse "${GITOPS_REMOTE}/${GITOPS_BRANCH}")
  if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "Kubernetes ${GITOPS_BRANCH} must match ${GITOPS_REMOTE}/${GITOPS_BRANCH} before restore." >&2
    exit 1
  fi
}

publish_gitops_generated() {
  local phase=$1
  local env_file="apps/dendenmushi/overlays/dev/env.properties"
  local inventory_file="apps/dendenmushi/overlays/dev/server-inventory.static.json"
  local changed_path unexpected=""

  while IFS= read -r changed_path; do
    changed_path=${changed_path:3}
    case "${changed_path}" in
      "${env_file}"|"${inventory_file}") ;;
      "") ;;
      *) unexpected+="${changed_path}"$'\n' ;;
    esac
  done < <(gitops_git status --porcelain --untracked-files=all)

  if [[ -n "${unexpected}" ]]; then
    echo "Unexpected Kubernetes changes after bootstrap:" >&2
    printf '%s' "${unexpected}" >&2
    exit 1
  fi

  kubectl kustomize "${KUBERNETES_DIR}/apps/dendenmushi/overlays/dev" >/dev/null
  gitops_git add -- "${env_file}" "${inventory_file}"
  if gitops_git diff --cached --quiet; then
    log "GitOps ${phase} values are already published."
    return
  fi

  gitops_git diff --cached --check
  gitops_git commit -m "deploy: refresh restored AWS ${phase}"
  gitops_git push "${GITOPS_REMOTE}" "HEAD:${GITOPS_BRANCH}"
}

configure_argocd_repository() {
  log "Registering the private GitOps repository with Argo CD."
  gh auth status --hostname "${GITHUB_HOST}" >/dev/null
  gh auth token --hostname "${GITHUB_HOST}" | tr -d '\r\n' | \
    kubectl_cmd create secret generic "${ARGOCD_REPOSITORY_SECRET_NAME}" \
      -n argocd \
      --from-literal=type=git \
      --from-literal="url=${GITOPS_REPO_URL}" \
      --from-literal=username=x-access-token \
      --from-file=password=/dev/stdin \
      --dry-run=client \
      -o yaml | \
    kubectl_cmd label --local -f - \
      argocd.argoproj.io/secret-type=repository \
      -o yaml | \
    kubectl_cmd apply -f - >/dev/null
}

wait_for_application_alb() {
  local deadline hostname=""
  deadline=$((SECONDS + ALB_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    hostname=$(kubectl_cmd get ingress \
      --all-namespaces \
      -l app=dendenmushi \
      -o jsonpath='{range .items[*].status.loadBalancer.ingress[*]}{.hostname}{"\n"}{end}' \
      2>/dev/null | sed -n '1p' || true)
    if [[ -n "${hostname}" ]]; then
      printf '%s\n' "${hostname}"
      return
    fi
    log "Waiting for the application ALB hostname."
    sleep "${RESTORE_POLL_SECONDS}"
  done

  echo "Timed out waiting for the application ALB hostname." >&2
  exit 1
}

wait_for_argocd_ready() {
  local deadline sync_status="" health_status=""
  deadline=$((SECONDS + ARGOCD_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    sync_status=$(kubectl_cmd get application dendenmushi-dev -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health_status=$(kubectl_cmd get application dendenmushi-dev -n argocd \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      log "Argo CD application is Synced and Healthy."
      return
    fi
    log "Waiting for Argo CD (sync=${sync_status:-unknown}, health=${health_status:-unknown})."
    sleep "${RESTORE_POLL_SECONDS}"
  done

  echo "Timed out waiting for Argo CD to become Synced and Healthy." >&2
  kubectl_cmd get application dendenmushi-dev -n argocd -o yaml >&2 || true
  exit 1
}

wait_for_application_dns() {
  local deadline
  deadline=$((SECONDS + DNS_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if [[ -n "$(dig +short "${APPLICATION_DOMAIN_NAME}" 2>/dev/null)" ]]; then
      log "DNS is resolving for ${APPLICATION_DOMAIN_NAME}."
      return
    fi
    log "Waiting for DNS propagation for ${APPLICATION_DOMAIN_NAME}."
    sleep "${RESTORE_POLL_SECONDS}"
  done

  echo "Timed out waiting for DNS propagation for ${APPLICATION_DOMAIN_NAME}." >&2
  exit 1
}

up() {
  require_up_commands
  backup_dir_for_read
  assert_restore_account
  require_gitops_publish_ready
  init_terraform

  log "Recreating main AWS infrastructure without application ALB DNS first."
  aws_tf apply \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -var="application_alb_dns_name="
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"

  assert_restore_account
  log "Recreating target host."
  "${TARGET_TERRAFORM_DIR}/scripts/bootstrap.sh" -auto-approve
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"

  if ! configure_kubectl; then
    echo "Cannot configure kubectl for restored EKS cluster ${CLUSTER_NAME}." >&2
    exit 1
  fi

  log "Bootstrapping Kubernetes secrets without starting application workloads."
  KUBECONFIG="${KUBECONFIG_FILE}" APPLY_ARGOCD_APPLICATION=false \
    "${KUBERNETES_DIR}/scripts/bootstrap-aws.sh"

  if [[ "${RESTORE_DB}" == "true" ]]; then
    restore_databases
    verify_database_counts
  fi

  publish_gitops_generated "target inventory"

  configure_argocd_repository
  log "Starting Argo CD reconciliation."
  kubectl_cmd apply -f "${KUBERNETES_DIR}/argocd/dendenmushi-dev-application.yaml"

  local alb_dns verify_log
  alb_dns=$(wait_for_application_alb)

  log "Refreshing GitOps values with the restored ALB ARN."
  KUBECONFIG="${KUBECONFIG_FILE}" APPLY_ARGOCD_APPLICATION=false \
    "${KUBERNETES_DIR}/scripts/bootstrap-aws.sh"
  publish_gitops_generated "ALB inventory"

  assert_restore_account
  log "Applying final Route 53 alias record for ${alb_dns}; hosted zone is preserved."
  aws_tf apply \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -var="application_alb_dns_name=${alb_dns}"

  wait_for_argocd_ready
  wait_for_application_dns

  log "Running AWS deployment verification."
  verify_log="${BACKUP_DIR}/restore-verify-aws.log"
  KUBECONFIG="${KUBECONFIG_FILE}" \
    "${KUBERNETES_DIR}/scripts/verify-aws.sh" | tee "${verify_log}"
  log "AWS restore completed successfully."
}

case "${ACTION}" in
  inventory)
    capture_inventory
    ;;
  backup)
    backup_all
    ;;
  down)
    down
    ;;
  restore-db)
    restore_databases
    ;;
  up)
    up
    ;;
  verify-down)
    verify_down
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

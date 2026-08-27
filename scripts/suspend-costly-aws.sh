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
NAMESPACE=${NAMESPACE:-dendenmushi}
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
  BACKUP_DIR=<backup-dir> $(basename "$0") up
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
  for command in aws terraform kubectl jq base64 date; do
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
    kubectl --kubeconfig "${KUBECONFIG_FILE}" \
      delete pod -n "${NAMESPACE}" -l app=ddm-cost-suspend-psql \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
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
  "namespace": "${NAMESPACE}",
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
    capture "${BACKUP_DIR}/k8s-dendenmushi-configmaps.txt" kubectl_cmd get configmaps -n "${NAMESPACE}"
    capture "${BACKUP_DIR}/k8s-dendenmushi-secrets-names.txt" kubectl_cmd get secrets -n "${NAMESPACE}"
    capture "${BACKUP_DIR}/k8s-dendenmushi-workloads.yaml" kubectl_cmd get deploy,svc,ingress,configmap -n "${NAMESPACE}" -o yaml
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
      metadata: {name: $pod, labels: {app: "ddm-cost-suspend-psql"}},
      spec: {
        restartPolicy: "Never",
        containers: [{
          name: "postgres",
          image: $image,
          command: ["sleep", "7200"],
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
  local pod="ddm-${label}-pg-$(date -u '+%H%M%S')"

  kubectl_cmd delete pod "${pod}" -n "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  psql_pod_manifest "${pod}" "${secret}" | kubectl_cmd apply -n "${NAMESPACE}" -f - >/dev/null
  kubectl_cmd wait --for=condition=Ready "pod/${pod}" -n "${NAMESPACE}" --timeout=180s >/dev/null
  printf '%s\n' "${pod}"
}

delete_psql_pod() {
  local pod=$1
  kubectl_cmd delete pod "${pod}" -n "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
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
  local pod
  local query
  query=$(table_count_query)

  log "Backing up PostgreSQL database ${label}"
  pod=$(start_psql_pod "${label}" "${secret}")
  trap 'delete_psql_pod "${pod}"' RETURN

  kubectl_cmd exec "${pod}" -n "${NAMESPACE}" -c postgres -- \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; pg_dump "$DATABASE_URL" --format=custom --no-owner --no-acl' \
    >"${BACKUP_DIR}/db-${label}.dump"

  kubectl_cmd exec "${pod}" -n "${NAMESPACE}" -c postgres -- \
    env TABLE_COUNT_QUERY="${query}" \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "$TABLE_COUNT_QUERY" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	"' \
    >"${BACKUP_DIR}/db-${label}-counts.tsv"

  kubectl_cmd exec "${pod}" -n "${NAMESPACE}" -c postgres -- \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "select current_database(), current_user, inet_server_addr(), inet_server_port();"' \
    >"${BACKUP_DIR}/db-${label}-connection.tsv"

  delete_psql_pod "${pod}"
  trap - RETURN
}

backup_databases() {
  if [[ "${SKIP_DB_BACKUP}" == "true" ]]; then
    log "Skipping PostgreSQL backup because SKIP_DB_BACKUP=true."
    return
  fi
  if ! configure_kubectl; then
    echo "Cannot back up PostgreSQL because EKS is not reachable." >&2
    exit 1
  fi
  backup_database "webapp" "dendenmushi-webapp-database"
  backup_database "incident" "dendenmushi-database"
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

  log "Deleting Kubernetes ingresses in ${NAMESPACE} so the ALB controller removes the ALB."
  kubectl_cmd get ingress -n "${NAMESPACE}" -o yaml >"${BACKUP_DIR}/k8s-ingresses-before-delete.yaml" 2>/dev/null || true
  kubectl_cmd delete ingress --all -n "${NAMESPACE}" --ignore-not-found --wait=true
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
  local dump_file="${BACKUP_DIR}/db-${label}.dump"
  local pod query

  if [[ ! -f "${dump_file}" ]]; then
    log "No dump found for ${label}: ${dump_file}; skipping."
    return
  fi

  log "Restoring PostgreSQL database ${label}"
  query=$(table_count_query)
  pod=$(start_psql_pod "${label}-restore" "${secret}")
  trap 'delete_psql_pod "${pod}"' RETURN

  kubectl_cmd exec -i "${pod}" -n "${NAMESPACE}" -c postgres -- \
    sh -c "cat > /tmp/${label}.dump" <"${dump_file}"
  kubectl_cmd exec "${pod}" -n "${NAMESPACE}" -c postgres -- \
    sh -c "DATABASE_URL=\$(printf \"%s\" \"\$DATABASE_URL\" | sed \"s/sslmode=no-verify/sslmode=require/g\"); export DATABASE_URL; pg_restore --clean --if-exists --no-owner --no-acl --dbname \"\$DATABASE_URL\" /tmp/${label}.dump"
  kubectl_cmd exec "${pod}" -n "${NAMESPACE}" -c postgres -- \
    env TABLE_COUNT_QUERY="${query}" \
    sh -c 'DATABASE_URL=$(printf "%s" "$DATABASE_URL" | sed "s/sslmode=no-verify/sslmode=require/g"); export DATABASE_URL; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	" -c "$TABLE_COUNT_QUERY" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F "	"' \
    >"${BACKUP_DIR}/db-${label}-counts-after-restore.tsv"

  delete_psql_pod "${pod}"
  trap - RETURN
}

restore_databases() {
  require_common_commands
  backup_dir_for_read
  if ! configure_kubectl; then
    echo "Cannot restore PostgreSQL because EKS is not reachable." >&2
    exit 1
  fi

  restore_database "webapp" "dendenmushi-webapp-database"
  restore_database "incident" "dendenmushi-database"

  for deployment in session-manager audit-service agent-controlplane incident-agent nest-backend; do
    kubectl_cmd rollout restart "deployment/${deployment}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
  done
}

up() {
  require_common_commands
  backup_dir_for_read
  init_terraform

  log "Recreating main AWS infrastructure without application ALB DNS first."
  aws_tf apply -auto-approve "${MAIN_TF_VAR_ARGS[@]}"
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"

  log "Recreating target host."
  "${TARGET_TERRAFORM_DIR}/scripts/bootstrap.sh" -auto-approve
  sleep "${POST_TERRAFORM_SLEEP_SECONDS}"

  log "Bootstrapping Kubernetes and GitOps environment."
  "${KUBERNETES_DIR}/scripts/bootstrap-aws.sh"

  if [[ "${RESTORE_DB}" == "true" ]]; then
    restore_databases
  fi

  log "Running AWS deployment verification."
  local verify_log alb_dns
  verify_log="${BACKUP_DIR}/restore-verify-aws.log"
  "${KUBERNETES_DIR}/scripts/verify-aws.sh" | tee "${verify_log}"
  alb_dns=$(awk '/^ALB DNS name:/ {print $4}' "${verify_log}" | tail -n 1)
  if [[ -z "${alb_dns}" ]]; then
    echo "Could not parse ALB DNS name from ${verify_log}" >&2
    exit 1
  fi

  log "Applying final Route 53 alias record for ${alb_dns}; hosted zone is preserved."
  aws_tf apply \
    -auto-approve \
    "${MAIN_TF_VAR_ARGS[@]}" \
    -var="application_alb_dns_name=${alb_dns}"
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

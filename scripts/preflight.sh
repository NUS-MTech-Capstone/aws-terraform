#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-southeast-1}
ROUTE53_ZONE=${ROUTE53_ZONE:-keiyam.me}
GITHUB_OIDC_URL=token.actions.githubusercontent.com

for command in aws; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS account: ${ACCOUNT_ID}"
echo "AWS region:  ${AWS_REGION}"

OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${GITHUB_OIDC_URL}')].Arn | [0]" \
  --output text)
if [[ -n "${OIDC_PROVIDER_ARN}" && "${OIDC_PROVIDER_ARN}" != "None" ]]; then
  echo "Existing GitHub OIDC provider: ${OIDC_PROVIDER_ARN}"
  echo "Use: -var='github_oidc_provider_arn=${OIDC_PROVIDER_ARN}'"
else
  echo "No GitHub OIDC provider found; Terraform will create one."
fi

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE}" \
  --max-items 1 \
  --query "HostedZones[?Name == '${ROUTE53_ZONE}.'].Id | [0]" \
  --output text)
if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]]; then
  echo "Route 53 zone not found: ${ROUTE53_ZONE}" >&2
  exit 1
fi
echo "Route 53 zone: ${ZONE_ID}"

for repository in \
  dendenmushi/sts \
  dendenmushi/session-manager \
  dendenmushi/proxy-controlplane \
  dendenmushi/proxy-dataplane \
  dendenmushi/ddm-agent; do
  if aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${repository}" >/dev/null 2>&1; then
    echo "Existing ECR repository: ${repository}"
    echo "Import before apply: terraform import 'aws_ecr_repository.services[\"${repository}\"]' '${repository}'"
  else
    echo "ECR repository will be created: ${repository}"
  fi
done


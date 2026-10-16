# AWS Infrastructure

Terraform for the DenDenMushi AWS foundation: VPC, EKS, ECR, Cognito, ACM,
Route 53, IAM/IRSA roles, Secrets Manager entries, managed database access, and
Argo CD bootstrap.

## What This System Does

This repository creates the cloud infrastructure used by the DenDenMushi SSH
access platform. It does not deploy application containers directly. Workloads
are promoted through immutable image digests and reconciled to EKS by the
Kubernetes GitOps repository.

The infrastructure supports:

- one HTTPS ALB hostname for Angular, Nest APIs, session control APIs, and
  WebSocket terminal upgrades
- Cognito authentication at the public boundary
- ECR repositories for deployable service images
- SNS and SQS resources for sanitized platform lifecycle metadata events
- EKS workload identities for Proxy Dataplane, Nest Backend, Agent Control
  Plane, Incident Agent, STS, Proxy Control Plane, Session Manager, and Audit
  Service
- CloudWatch Container Insights and short-retention container logs
- scoped Secrets Manager access for SSH target credentials and application
  database URLs
- Route 53 and ACM resources for `api.ddm.keiyam.me`
- Argo CD installed privately in the cluster for workload reconciliation

The default EKS managed node group uses two `t3.medium` nodes to provide pod
capacity for system add-ons, application workloads and Argo CD.

## Low-Retention Observability

This capstone environment intentionally keeps AWS observability data short-lived
to reduce cost and sensitive operational metadata exposure:

- EKS control-plane logging enables only `api`, `audit`, and `authenticator`.
- The EKS control-plane log group uses one-day CloudWatch Logs retention.
- Container Insights log groups for application, dataplane, host, performance,
  and Prometheus data are pre-created with one-day retention.
- The Amazon CloudWatch Observability EKS add-on is installed through EKS Pod
  Identity with `CloudWatchAgentServerPolicy`.
- Application Signals auto-instrumentation excludes the metadata-only Agent
  Tool Gateway, which is covered by Container Insights and JSON application logs.
- Application traces are disabled by default in Kubernetes manifests. X-Ray or
  OTLP trace export should only be enabled temporarily for a demo/debug session.
- Incident Reasoning Agent LangSmith tracing is dev/debug observability only. Terraform
  creates `dendenmushi/incident-agent/langsmith-api-key-dev` in Secrets
  Manager. The Reasoning Agent role can invoke Bedrock and read only that
  optional tracing secret; the coordinator role is limited to SQS and its
  database URL. The application exporter sends allowlisted trace metadata with
  empty inputs and outputs.
- Terraform creates the
  `dendenmushi/incident-agent/openai-api-key-dev` Secrets Manager container for
  an AgentCore inference-gateway credential. Populate it with a JSON `api_key`
  field through Secrets Manager only. A small CloudFormation credential stack
  references that external JSON field without importing it into Terraform
  state, while a second stack creates the IAM-authenticated gateway, built-in
  `openai` inference target, and fail-open 10 requests/minute plus 100,000
  tokens/minute target limit. The Reasoning Agent can invoke only that gateway
  and cannot read this secret; the gateway execution role can read only the
  exact credential provider and secret.
  AgentCore also evaluates credential retrieval against the service-owned
  `default` token vault, its generated workload identity, and the `default`
  workload-identity directory. The execution policy therefore lists those
  exact required parents and denies every resource outside the OpenAI
  credential/gateway set.
- Application services emit CloudWatch Embedded Metric Format (EMF) JSON to
  stdout in the `DenDenMushi` namespace. The alarm set in
  `observability_alarms.tf` watches the hardening symptoms: authentication
  failures, STS errors/latency, session start and assignment failures, stale
  proxy pods, heartbeat misses, WebSocket disconnect errors, SSH failures, low
  proxy pod capacity, and agent-controlplane remediation plus incident-agent
  SQS/Bedrock/OpenAI failures and AgentCore gateway throttling.
- `observability_alarms.tf` also creates the
  `${name}-${env}-application-observability` CloudWatch dashboard. The dashboard
  includes live EKS Container Insights panels, AWS dependency panels for the
  ALB, RDS, NAT Gateway, and Incident Agent SQS queue, optional target-host demo
  panels, app-level EMF metric views, and the operational alarm strip. The
  target-host panels populate after `target-hosts-setup` is applied and the
  target CloudWatch Agent has emitted metrics.
- Alarm actions publish to the existing incident alert SNS topic, which is
  subscribed to the Incident Agent SQS queue. The topic uses a
  customer-managed KMS key instead of `alias/aws/sns` so CloudWatch Alarms has
  explicit key permission to publish encrypted alarm notifications.
- The platform lifecycle timeline uses a separate SNS topic, `ddm-events-${env}`,
  with an Audit Service queue subscription and a
  bounded DLQ redrive policy. STS, Proxy Control Plane, Session Manager, and
  Agent Control Plane can publish sanitized metadata; Audit Service consumes the
  queue and stores queryable event metadata.

CloudWatch Logs marks expired events for deletion at the retention boundary, but
physical deletion can lag. CloudWatch metric retention is AWS-managed and cannot
be reduced to one day, so keep custom metrics minimal.

## Architecture

```text
Route 53 + ACM
  -> AWS Load Balancer Controller / ALB
  -> EKS workloads from kubernetes/
     - Angular
     - Nest Backend
     - STS
     - Session Manager
     - Audit Service
     - Proxy Control Plane
     - Proxy Dataplane
     - Agent Control Plane
     - Incident Agent
     - Incident Reasoning Agent
     - Agent Tool Gateway

Cognito authenticates browser users.
IRSA grants workloads narrow AWS permissions.
Secrets Manager stores generated database URLs and target credentials.
ECR stores immutable service images.
SNS and SQS carry sanitized lifecycle metadata to Audit Service.
```

Ingress ownership after Kubernetes is deployed:

```text
/                         -> Angular
/ddm/auth/login           -> Nest Backend with ALB authentication redirect
/ddm/*                    -> Nest Backend
/sessions/*/ws            -> Proxy Dataplane
/sessions/*               -> Proxy Control Plane
/agentic-ai/health        -> Agent Control Plane
/alerts*                  -> Agent Control Plane
/incidents*               -> Agent Control Plane
```

Live terminal traffic remains direct between the browser, Proxy Dataplane, and
target host. Terraform does not introduce a broker or alternate terminal data
path.

Relevant event-lane outputs:

```bash
terraform output -raw events_topic_arn
terraform output -raw audit_events_queue_url
terraform output -raw sts_role_arn
terraform output -raw proxy_controlplane_role_arn
terraform output -raw session_manager_role_arn
terraform output -raw audit_service_role_arn
```

Producer roles can only publish to the lifecycle SNS topic. Audit Service can
only receive, delete, change visibility for, and inspect attributes on the audit
events queue.

## How To Run Local Demo

The local demo does not use this Terraform stack. Run it from the workspace
root with Docker Compose:

```bash
cd ..
docker compose up --build
```

The separately supplied workspace `capstone/README.md` describes the local
inventory and WebSocket session steps.

## How To Deploy To AWS

Prerequisites:

- AWS credentials for the target account
- Terraform
- AWS CLI
- `kubectl`
- `jq`
- Route 53 control of `ddm.keiyam.me`
- at least one Cognito operator to place in the `Admin` group before webapp
  cutover

Start with a credential and configuration check:

```bash
export AWS_PROFILE=capstone
aws sts get-caller-identity
./scripts/preflight.sh
terraform init -reconfigure
terraform validate
```

Apply the base infrastructure:

```bash
terraform plan -var-file=secrets.tfvars -var-file=teammate-access.local.tfvars
terraform apply -var-file=secrets.tfvars -var-file=teammate-access.local.tfvars
```

When enabling Incident Agent LangSmith tracing, set the API key in
`secrets.tfvars` before applying:

```hcl
langsmith_api_key = "..."
# Optional. Defaults to dendenmushi-incident-agent-dev.
langsmith_project = "dendenmushi-incident-agent-dev"
# Optional. Leave unset for the LangSmith default endpoint/workspace.
langsmith_endpoint     = ""
langsmith_workspace_id = ""
```

Terraform stores secret values in state even when variables are marked
sensitive, so treat the Terraform backend and local plan files as sensitive.
Do not expect traces from the dev deployment until the API key secret version
has been created from this tfvars value.

If the account already has a GitHub Actions OIDC provider, pass its ARN instead
of creating a duplicate provider:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars \
  -var='github_oidc_provider_arn=arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'
```

The preflight script reports existing ECR repositories and prints the matching
`terraform import` commands. Import existing repositories before applying so
Terraform does not attempt to recreate them.

Create or assign at least one Cognito user to the capital `Admin` group before
the first webapp deployment. Terraform creates the groups but does not manage
individual user membership. Assign the operator using the Cognito username or UUID.

```bash
POOL_ID=$(terraform output -raw cognito_user_pool_id)
aws cognito-idp admin-add-user-to-group \
  --region ap-southeast-1 \
  --user-pool-id "${POOL_ID}" \
  --username "<cognito-username-or-uuid>" \
  --group-name Admin
```

Import existing Cognito groups and managed-login branding before applying.
For a group:

```bash
POOL_ID=$(terraform output -raw cognito_user_pool_id)
terraform import 'aws_cognito_user_group.webapp["Admin"]' "${POOL_ID}/Admin"
```

Deploy the target host stack, publish the service images, then bootstrap the
Kubernetes environment:

```bash
cd ../target-hosts-setup
./scripts/bootstrap.sh -auto-approve

cd ../kubernetes
./scripts/bootstrap-aws.sh
```

`bootstrap-aws.sh` configures `kubectl`, creates or preserves runtime secrets,
bootstraps the webapp database login, reads target host outputs, keyscans the
target from inside EKS, refreshes the dev overlay, and applies the Argo CD
Application. Review and commit generated changes in:

```text
kubernetes/apps/dendenmushi/overlays/dev/env.properties
kubernetes/apps/dendenmushi/overlays/dev/server-inventory.static.json
```

After service image promotion PRs are merged and Argo CD syncs the workloads,
verify the deployment:

```bash
./scripts/verify-aws.sh
```

The first Terraform apply leaves `application_alb_dns_name` empty because
Kubernetes has not created the application ALB yet. After verification prints
the ALB hostname, create or update the Route 53 alias:

```bash
cd ../aws-terraform
terraform apply \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars \
  -var='application_alb_dns_name=<ALB DNS name>'
```

## Suspend Costly AWS Resources

For a multi-month pause, use the single suspend script instead of manually
deleting resources from the console:

```bash
cd aws-terraform
CONFIRM_DESTROY=destroy-costly-aws ./scripts/suspend-costly-aws.sh down
```

The script first writes an ignored local backup under
`aws-terraform/ignore/aws-cost-suspension/<timestamp>/`. That directory is
sensitive local state: it contains Terraform/AWS/Kubernetes inventory, Cognito
metadata, ECR image metadata, and PostgreSQL custom-format dumps for the webapp
and incident/session databases. Do not commit or share it.

The teardown removes the resources that materially drive the idle bill:

- Kubernetes ingresses and the Kubernetes-owned application ALB.
- Target-host EC2 infrastructure from `target-hosts-setup`.
- The RDS PostgreSQL instance after the local pg_dump backups are captured.
- EKS add-ons, Helm releases, managed node group, and EKS control plane.
- The NAT gateway, private NAT route, and NAT EIP.

Route 53 hosted zones are never deleted. The script removes only the application
alias record for the deleted ALB. It leaves low-cost restore anchors such as
ECR repositories/images, Cognito, IAM, Secrets Manager entries, SQS/SNS, S3,
subnets, route tables, and the VPC skeleton unless Terraform must recreate a
dependent object. Keeping the VPC skeleton is intentional: VPCs, subnets, route
tables, security groups, and the gateway S3 endpoint do not have the same idle
monthly cost profile as EKS, RDS, ALB, NAT gateway, and EC2, and preserving them
makes a future demo restore less error-prone.

To inspect without deleting anything:

```bash
./scripts/suspend-costly-aws.sh inventory
./scripts/suspend-costly-aws.sh backup
```

To restore later, keep the backup directory available and run:

```bash
AWS_PROFILE=capstone \
BACKUP_DIR=ignore/aws-cost-suspension/<timestamp> \
EXPECTED_AWS_ACCOUNT_ID=<12-digit-account-id> \
PUBLISH_GITOPS=true \
  ./scripts/suspend-costly-aws.sh up
```

`up` verifies that the active AWS caller matches both
`EXPECTED_AWS_ACCOUNT_ID` and the account saved in the backup before changing
anything. It reapplies the main Terraform stack with the stale ALB value
cleared, recreates the target host, bootstraps Kubernetes secrets, and restores
PostgreSQL before application workloads start. Database dumps are copied into
the restore pod and verified by SHA-256 before restore. It then publishes
regenerated GitOps inventory to the clean Kubernetes `main` branch, waits for
Argo CD and the new ALB, applies only the application Route 53 alias, and runs
`kubernetes/scripts/verify-aws.sh`. The Route 53 hosted zone is never replaced
or deleted. Set `RESTORE_DB=false` only when the database contents are
intentionally disposable. Because the GitOps repository is private, `up` also
registers it in Argo CD using the existing GitHub CLI keyring login; run
`gh auth status --hostname github.com` before restoring.

### GitHub OIDC And Promotion

The ECR push role is restricted to the service repositories declared in
`github_oidc.tf`, including `audit-service`, `nest-backend`, and `angular`:

```bash
terraform output -raw github_ecr_push_role_arn
```

### Terraform CI and read-only AWS plans

CI always runs formatting checks, locked provider initialization with the backend
disabled, and configuration validation. A dependent job then runs a real refreshed
AWS plan through the dedicated `github_terraform_plan_role_arn` OIDC role.
Only same-repository PRs and the configured `main`/`dev` branches may plan. Fork
PRs receive credential-free validation. Manual dispatch is restricted to those
branches. The shared workflow is pinned to a reviewed source commit.

Configure these GitHub Actions secrets without printing their values:

- `AWS_TERRAFORM_PLAN_ROLE_ARN`: the existing Terraform planning role output.
- `TERRAFORM_TFVARS_HCL`: the local `secrets.tfvars` contents, with the ALB DNS
  value checked against the currently deployed named ALB before publishing.
- `TERRAFORM_TEAMMATE_TFVARS_HCL`: the exact local `teammate-access.local.tfvars` contents.

Both variable files are mandatory for CI. Do not copy a stale ALB DNS override
into CI: the existing Route 53 precondition deliberately rejects it. Correct the
protected CI copy after checking the named ALB; preserve user-owned local secret
files unless explicitly authorized to edit them. Local planning includes both files:

```bash
AWS_PROFILE=capstone terraform plan \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars
```

The role retains AWS read-only permissions, state reads for both project stacks,
reads of the four Terraform-managed secret versions, and narrowly scoped EKS
read access for managed resources and Helm release storage. It cannot mutate
state or workloads, execute commands, or apply a Terraform plan. Bootstrap only
the planning-role IAM policies, EKS access entry and associated read-only RBAC
from a reviewed saved plan using an authenticated local operator. Reject any
unrelated resource changes in that bootstrap plan.

CI uses `-lock=false` with its read-only state role; do not run infrastructure
applies concurrently. Exit codes 0 and 2 mean planning completed successfully;
proposed changes are reported, never applied. Sanitized plan summaries and
validation results are retained for 14 days, including failures. Raw plans,
state and variable files must not be committed or uploaded.

After retiring AWS, explicitly set repository variable
`TERRAFORM_LIVE_PLAN_ENABLED=false` to retain configuration validation only.
The job summary then states that no live AWS plan was performed. While AWS is
active, leave the variable unset or `true`; missing credentials or backend access
must fail CI. CI performs validation and read-only planning; infrastructure
applies are operator-run.

### Argo CD Access

Terraform installs Argo CD in the private `argocd` namespace through a pinned
upstream Helm chart. The Argo CD server is a `ClusterIP` service; use
`kubectl port-forward` for admin access instead of exposing it publicly:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Read the initial admin password only from the cluster:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

After the first login, rotate or remove the bootstrap admin credential according
to the Argo CD hardening path you choose for the environment.

### Teammate Access

Teammate access is opt-in and managed by Terraform. The default policy grants:

- readonly AWS diagnostics for CloudWatch Logs, CloudWatch metrics, EKS, EC2,
  load balancers, ECR, RDS, Route 53, ACM, IAM metadata, tags, and secret
  metadata
- Cognito admin access scoped to this project's user pool
- S3 admin access scoped to the project static-files bucket
- readonly Kubernetes access through an EKS access entry
- readonly Argo CD access through a local Argo CD account
- permission for the IAM user to change their own AWS console password
- permission for the IAM user to manage their own AWS CLI access keys and MFA
- AWS CloudShell access for browser-based CLI work

Set `teammate_access_database_shell=true` only for teammates who need direct
SQL access. It adds `secretsmanager:GetSecretValue` for the project database
connection secrets and Kubernetes RBAC in `dendenmushi` so they can run
temporary `psql` pods.

Set `teammate_access_argocd_port_forward=true` for teammates who need to open
the private Argo CD UI with `kubectl -n argocd port-forward
svc/argocd-server 8080:443`.

Create the IAM user, EKS access entry, and Argo CD local account. Keep these
non-secret settings in an ignored local tfvars file so a later apply does not
accidentally remove teammate access:

```hcl
teammate_access_user_names = [
  "<aws-iam-username>",
]

argocd_readonly_accounts = [
  "<argocd-username>",
]
```

Then apply both tfvars files:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars
```

If the teammate already has an IAM user, add the existing username instead of
asking Terraform to create a new IAM user:

```hcl
teammate_access_existing_user_names = [
  "<aws-iam-username>",
]

argocd_readonly_accounts = [
  "<argocd-username>",
]
```

Grant direct SQL shell access by adding this to the same local tfvars file:

```hcl
teammate_access_database_shell = true
```

Grant Argo CD port-forward access by adding this to the same local tfvars file:

```hcl
teammate_access_argocd_port_forward = true
```

Attach any extra AWS managed policies by name:

```hcl
teammate_access_extra_aws_managed_policy_names = [
  "SignInLocalDevelopmentAccess",
]
```

Attach customer-managed policies from this AWS account with
`teammate_access_extra_policy_names`, or pass full ARNs with
`teammate_access_extra_policy_arns`.

For an existing IAM role, pass the role ARN with
`teammate_access_principal_arns`; that grants Kubernetes access through an EKS
access entry. Attach AWS console and Secrets Manager permissions to the role
separately if needed, because the IAM group policy applies only to IAM users.

Only set `teammate_access_full_s3_admin=true` when the teammate really needs
admin access to every S3 bucket in the account. The default avoids broad S3 read
access because the Terraform state bucket may contain sensitive values.

Set the IAM console password out of band so the password is not stored in
Terraform state:

```bash
aws iam create-login-profile \
  --user-name "<aws-iam-username>" \
  --password-reset-required \
  --password '<temporary-password>'
```

The teammate can configure readonly `kubectl` access with:

```bash
aws eks update-kubeconfig \
  --name "$(terraform output -raw cluster_name)" \
  --region ap-southeast-1

kubectl auth can-i get pods -n dendenmushi-ssh
kubectl auth can-i delete pods -n dendenmushi-ssh
```

The first command should return `yes`; the delete check should return `no`
unless `teammate_access_database_shell=true` is enabled.

With database shell access enabled, verify secret and temporary pod access:

```bash
aws secretsmanager get-secret-value \
  --region ap-southeast-1 \
  --secret-id dendenmushi/incident-agent/database-url-dev \
  --query SecretString \
  --output text

kubectl auth can-i create pods -n dendenmushi-ssh
kubectl auth can-i create pods/attach -n dendenmushi-ssh
kubectl auth can-i delete pods -n dendenmushi-ssh
kubectl auth can-i create pods -n dendenmushi-webapp
```

Set the Argo CD readonly account password after Terraform applies the account:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443

argocd login localhost:8080 --username admin --password '<admin-password>' --insecure
argocd account update-password \
  --account '<argocd-username>' \
  --current-password '<admin-password>' \
  --new-password '<temporary-password>'
```

The teammate can then log in through the same port-forwarded endpoint and view
applications without sync or mutation permissions.

## How To Verify Success

Terraform checks:

```bash
terraform validate
terraform output ecr_repository_urls
terraform output proxy_dataplane_role_arn
terraform output nest_backend_role_arn
terraform output incident_reasoning_agent_role_arn
terraform output agentcore_openai_gateway_arn
terraform output agentcore_openai_gateway_url
terraform output webapp_database_secret_id
terraform output application_certificate_arn
terraform output cognito_user_pool_arn
terraform output cognito_client_id
terraform output cognito_domain
terraform output configure_kubectl
```

Cluster checks:

```bash
cd ../kubernetes
./scripts/verify-aws.sh
kubectl get application dendenmushi-dev -n argocd
kubectl get pods,ingress -n dendenmushi-ssh
kubectl get pods,ingress -n dendenmushi-agentic
kubectl get pods,ingress -n dendenmushi-webapp
```

Application checks:

```bash
curl -fsS https://api.ddm.keiyam.me/healthz
curl -fsS https://api.ddm.keiyam.me/readyz
```

Expected result:

- the active application deployments roll out successfully
- the ALB hostname is available on the `proxy-controlplane` ingress
- Route 53 points `api.ddm.keiyam.me` to the ALB after the second Terraform
  apply
- public health endpoints succeed
- Cognito-authenticated users can load Angular and start SSH sessions
- WebSocket terminal upgrades go through
  `wss://api.ddm.keiyam.me/sessions/{sessionId}/ws`

## Provider lockfile maintenance

Provider versions are unchanged by platform checksum maintenance. When refreshing
checksums for the supported macOS development and Linux CI platforms, run:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

Commit the reviewed lockfile; CI continues to enforce `-lockfile=readonly`.

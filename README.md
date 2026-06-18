# AWS Infrastructure

Terraform for the DenDenMushi AWS foundation: VPC, EKS, ECR, Cognito, ACM,
Route 53, IAM/IRSA roles, Secrets Manager entries, managed database access, and
Argo CD bootstrap.

## What This System Does

This repository creates the cloud infrastructure used by the DenDenMushi SSH
access platform. It does not deploy application containers directly. Workloads
are promoted through image tags and reconciled to EKS by the Kubernetes GitOps
repository.

The infrastructure supports:

- one HTTPS ALB hostname for Angular, Nest APIs, session control APIs, and
  WebSocket terminal upgrades
- Cognito authentication at the public boundary
- ECR repositories for deployable service images
- EKS workload identities for Proxy Dataplane, Nest Backend, and Incident Agent
- scoped Secrets Manager access for SSH target credentials and application
  database URLs
- Route 53 and ACM resources for `api.ddm.keiyam.me`
- Argo CD installed privately in the cluster for workload reconciliation

The default EKS managed node group desires two `t3.medium` nodes and permits a
minimum of one. A single `t3.medium` only exposes 17 pod slots, which is not
enough for Kubernetes system add-ons, DenDenMushi workloads, and Argo CD
together.

## Architecture

```text
Route 53 + ACM
  -> AWS Load Balancer Controller / ALB
  -> EKS workloads from kubernetes/
     - Angular
     - Nest Backend
     - STS
     - Session Manager
     - Proxy Control Plane
     - Proxy Dataplane

Cognito authenticates browser users.
IRSA grants workloads narrow AWS permissions.
Secrets Manager stores generated database URLs and target credentials.
ECR stores immutable service images.
```

Ingress ownership after Kubernetes is deployed:

```text
/                         -> Angular
/ddm/auth/login           -> Nest Backend with ALB authentication redirect
/ddm/*                    -> Nest Backend
/sessions/*/ws            -> Proxy Dataplane
/sessions/*               -> Proxy Control Plane
/incidents*               -> Incident Agent
```

Live terminal traffic remains direct between the browser, Proxy Dataplane, and
target host. Terraform does not introduce a broker or alternate terminal data
path.

## How To Run Local Demo

The local demo does not use this Terraform stack. Run it from the workspace
root with Docker Compose:

```bash
cd ..
docker compose up --build
```

See the root [README.md](../README.md) for local target inventory and
WebSocket session steps.

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
aws sts get-caller-identity
./scripts/preflight.sh
terraform init -reconfigure
terraform validate
```

Apply the base infrastructure:

```bash
terraform apply -var-file=secrets.tfvars
```

If the account already has a GitHub Actions OIDC provider, pass its ARN instead
of creating a duplicate provider:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var='github_oidc_provider_arn=arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'
```

The preflight script reports existing ECR repositories and prints the matching
`terraform import` commands. Import existing repositories before applying so
Terraform does not attempt to recreate them.

Create or assign at least one Cognito user to the capital `Admin` group before
the first webapp deployment. Terraform creates the groups but does not manage
individual user membership because Cognito pools configured with email aliases
use internal UUID usernames that are awkward to manage declaratively.

```bash
POOL_ID=$(terraform output -raw cognito_user_pool_id)
aws cognito-idp admin-add-user-to-group \
  --region ap-southeast-1 \
  --user-pool-id "${POOL_ID}" \
  --username "<cognito-username-or-uuid>" \
  --group-name Admin
```

If one of the exact webapp groups already exists in the user pool, import it
before applying. For example:

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
  -var='application_alb_dns_name=<ALB DNS name>'
```

### GitHub OIDC And Promotion

The ECR push role is restricted to the service repositories declared in
`github_oidc.tf`, including `nest-backend` and `angular`:

```bash
terraform output -raw github_ecr_push_role_arn
```

Terraform CI and apply use separate GitHub OIDC roles:

```bash
terraform output -raw github_terraform_plan_role_arn
terraform output -raw github_terraform_apply_role_arn
```

Store these as `AWS_TERRAFORM_PLAN_ROLE_ARN` and
`AWS_TERRAFORM_APPLY_ROLE_ARN`. Configure required reviewers on the repository's
`dev` GitHub environment before enabling apply. The roles must first be
bootstrapped with one authenticated local Terraform apply before the OIDC
workflows can assume them.

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

## How To Verify Success

Terraform checks:

```bash
terraform validate
terraform output ecr_repository_urls
terraform output proxy_dataplane_role_arn
terraform output nest_backend_role_arn
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
kubectl get pods,ingress -n dendenmushi
```

Application checks:

```bash
curl -fsS https://api.ddm.keiyam.me/healthz
curl -fsS https://api.ddm.keiyam.me/readyz
```

Expected result:

- the six active SSH-path deployments roll out successfully
- the ALB hostname is available on the `proxy-controlplane` ingress
- Route 53 points `api.ddm.keiyam.me` to the ALB after the second Terraform
  apply
- public health endpoints succeed
- Cognito-authenticated users can load Angular and start SSH sessions
- WebSocket terminal upgrades go through
  `wss://api.ddm.keiyam.me/sessions/{sessionId}/ws`

## Known Limitations

- The first infrastructure apply cannot create the final Route 53 ALB alias
  because the ALB is created later by Kubernetes.
- Terraform creates Cognito groups, but operator membership in `Admin` is a
  manual or scripted operational step.
- Changing an existing Cognito domain between Hosted UI classic and managed
  login can take a few minutes to propagate and invalidates existing
  Cognito login-page sessions.
- If a Cognito managed-login branding style already exists for the app client,
  import it before applying Terraform.
- The Incident Agent infrastructure is present, but incident-agent workflows
  are outside the core SSH session verification path.
- Destroying the stack should be planned carefully because EKS load balancers,
  Route 53 aliases, secrets, and target-host dependencies may have cross-repo
  ownership.

# AGENTS.md

## Repository Scope

This repository owns AWS infrastructure for DenDenMushi.

Primary responsibilities:

- EKS cluster, node groups, IAM, OIDC, and cluster access.
- VPC, subnets, routing, NAT, and security groups.
- AWS Load Balancer Controller installation and IAM role.
- ACM, Route 53, DNS-related outputs, S3, RDS, Secrets Manager, Argo CD,
  CloudWatch, SNS/SQS, and other AWS resources.

Do not put application Kubernetes manifests here unless Terraform must own that
resource. Workload manifests should live in the `kubernetes` repository so
Argo CD can use it as the GitOps source.

## Current Direction

The Phase 1 baseline runs on EKS and uses:

- AWS Load Balancer Controller.
- ALB ingress with `ingressClassName: alb`.
- ALB target type `ip`.
- ECR images built by service repositories through shared GitHub Actions and
  promoted to the Kubernetes GitOps repository.
- Argo CD installed privately in the cluster for workload reconciliation.
- Cognito authentication at the public ALB boundary.
- IRSA or EKS Pod Identity for workload AWS access.
- Secrets Manager for target credentials and application database URLs.
- CloudWatch alarms routed through SNS/SQS for the Incident Agent.

Terraform should provision cluster infrastructure and AWS dependencies, not
perform application deployment.

## Phase 2 Agent Guardrails

AI-agent infrastructure changes must stay bounded and explicit:

- Add only the AWS resources required by a concrete agent consumer and delivery
  requirement.
- Prefer workload identity, least-privilege IAM, and short-lived STS capability
  tokens over shared long-lived secrets.
- Do not add infrastructure that brokers live terminal traffic.
- Do not grant agents broad AWS, Kubernetes, database, or Secrets Manager
  permissions for convenience.
- Keep alarm, queue, and log retention intentional; avoid storing prompts,
  command bodies, tokens, private keys, or terminal streams.
- If Bedrock, LangSmith, evaluation storage, or new queues are added, document
  data flow, retention, IAM scope, failure behavior, and cost impact.

## Change Rules

- Keep Terraform changes minimal, explicit, and reviewable.
- Do not broad-refactor modules or naming unless asked.
- Do not modify `secrets.tfvars` unless explicitly requested.
- Do not commit generated local state, kubeconfig files, or `.terraform`
  internals.
- Prefer outputs over hardcoded values when other repos need AWS identifiers.
- Preserve the existing `ap-southeast-1` / `dev` defaults unless requested.

## Validation

Before completing Terraform changes, run when possible:

```bash
terraform fmt -recursive
terraform validate
```

If provider/module initialization is needed:

```bash
terraform init
```

Do not run `terraform apply` or `terraform destroy` unless explicitly requested.

## EKS Notes

Application manifests should assume the AWS Load Balancer Controller is installed
by this repo. If manifests need new AWS permissions, add the minimal IAM policy
or IRSA role here and document which Kubernetes service account uses it.

Avoid introducing service mesh, custom controllers, or complex networking until
there is a demonstrated operational requirement.

# AGENTS.md

## Repository Scope

This repository owns AWS infrastructure for DenDenMushi.

Primary responsibilities:

- EKS cluster, node groups, IAM, OIDC, and cluster access.
- VPC, subnets, routing, NAT, and security groups.
- AWS Load Balancer Controller installation and IAM role.
- ACM, CloudFront, DNS-related outputs, S3, RDS, and other AWS resources.

Do not put application Kubernetes manifests here unless Terraform must own that
resource. Workload manifests should live in the `kubernetes` repository so
ArgoCD can use it as the GitOps source.

## Current Direction

The MVP runs on EKS and uses:

- AWS Load Balancer Controller.
- ALB ingress with `ingressClassName: alb`.
- ALB target type `ip`.
- ECR images built by service repositories through shared GitHub Actions.
- Kubernetes manifests managed outside Terraform.

Terraform should provision cluster infrastructure and AWS dependencies, not
perform application deployment.

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
the MVP is working end to end.

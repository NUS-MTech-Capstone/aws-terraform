# AWS Infrastructure

Terraform for the DenDenMushi VPC, EKS cluster, Cognito, application
certificate, ECR repositories, and workload IAM roles.

## Apply

Refresh AWS credentials before running Terraform:

```bash
aws sts get-caller-identity
./scripts/preflight.sh
terraform init -reconfigure
terraform validate
terraform apply -var-file=secrets.tfvars
```

The first apply leaves `application_alb_dns_name` empty because Kubernetes has
not created the application ALB yet. After `kubernetes/scripts/deploy-aws.sh`
prints the ALB hostname, create the Route 53 record:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var='application_alb_dns_name=<ALB DNS name>'
```

## GitHub OIDC

By default Terraform creates the account-wide GitHub Actions OIDC provider. If
one already exists, pass it instead:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var='github_oidc_provider_arn=arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'
```

The preflight script also reports existing ECR repositories and prints the
corresponding `terraform import` commands. Import existing repositories before
applying so Terraform does not attempt to recreate them.

The ECR push role is restricted to the five service repositories:

```bash
terraform output -raw github_ecr_push_role_arn
```

The proxy-dataplane role can only read secrets under:

```text
dendenmushi/targets/*
```

## Useful Outputs

```bash
terraform output ecr_repository_urls
terraform output proxy_dataplane_role_arn
terraform output application_certificate_arn
terraform output cognito_user_pool_arn
terraform output cognito_client_id
terraform output cognito_domain
terraform output configure_kubectl
```

## Existing Test Stack

The existing nginx, CloudFront, and root-domain test resources remain in this
stack. They are independent from the `api.ddm.keiyam.me` application ingress.


# 1. Initialize Terraform
terraform init

# 2. Validate configuration
terraform validate

# 3. Plan to see what will be created
terraform plan

# 4. Apply (this will take 10-15 minutes for EKS)
terraform apply -auto-approve

# 5. Configure kubectl
aws eks update-kubeconfig --region ap-southeast-1 --name ddm-cluster-dev

# 6. Verify cluster is working
kubectl get nodes
kubectl get pods -A

# 7. Test by deploying nginx
kubectl create deployment test --image=nginx
kubectl expose deployment test --port=80 --type=LoadBalancer
kubectl get svc test -w  # Wait for external IP

# IMPORTANT: EKS costs money even when idle!
# Delete everything when done with project:

# 1. Delete all workloads first
kubectl delete all --all --all-namespaces

# 2. Delete EKS cluster (Terraform will handle this)
terraform destroy -auto-approve


```bash
terraform init -reconfigure

terraform apply -target=aws_acm_certificate.cf -var-file=secrets.tfvars
terraform output cf_validation_records
terraform apply -var-file=secrets.tfvars


```

After apply finishes, create the final root-account DNS record:

ddm.keiyam.me -> terraform output cloudfront_domain_name


## AWS Config

```bash
export AWS_ACCESS_KEY_ID="XXXX"
export AWS_SECRET_ACCESS_KEY="XXXXX"
export AWS_REGION="ap-southeast-1"
```

With profiles
```bash
aws configure --profile capstone
export AWS_PROFILE=capstone
```

Check 
```bash
aws sts get-caller-identity
terraform init -reconfigure
```
aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn "arn:aws:acm:us-east-1:891377133321:certificate/9b095d25-a65f-4164-a895-3a977603b210" \
  --query 'Certificate.DomainValidationOptions[*].{DomainName:DomainName,Status:ValidationStatus,Name:ResourceRecord.Name,Type:ResourceRecord.Type,Value:ResourceRecord.Value}' \
  --output table


## EKS Access

```bash
aws eks update-kubeconfig --name dendenmushi-cluster-dev --region ap-southeast-1
kubectl get all -A
```

# After done
kubectl delete ingress dendenmushi-ok-dev -n default
## above will hang so need manually delete alb
terraform destroy -var-file=secrets.tfvars

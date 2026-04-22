# aws


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

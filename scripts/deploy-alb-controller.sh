#!/bin/bash
# Run this AFTER terraform apply

# Get AWS account ID
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Install cert manager (prerequisite for ALB controller)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# Wait for cert manager to be ready
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app=cert-manager \
  --timeout=90s

# Add helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${var.name}-cluster-${var.env} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${var.aws_region} \
  --set vpcId=$(terraform output -raw vpc_id)
#!/bin/bash

set -euo pipefail

# run from repo root
ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# only run if there are Terraform files staged or modified
# if ! git diff --cached --name-only | grep -E '\.tf$|\.tfvars$' >/dev/null 2>&1; then
#   exit 0
# fi

echo "terraform fmt"
terraform fmt -recursive

# restage files if fmt changed
git add -u

echo "terraform init"
terraform init -input=false -backend=false -no-color >/dev/null

echo "terraform validate"
terraform validate -no-color

echo "terraform precommit checks passed"

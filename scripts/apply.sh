#!/bin/bash

set -e

terraform apply -var-file="secrets.tfvars"
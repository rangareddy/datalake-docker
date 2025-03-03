#!/bin/bash
set -e

export XTABLE_HOME=${XTABLE_HOME:-/opt/xtable}

# Configure AWS Default Profile
echo "-----------------------------------------------------------------"
echo "Configuring the AWS Profile..."
AWS_DEFAULT_PROFILE="default"
aws configure set profile $AWS_DEFAULT_PROFILE
aws configure set profile.$AWS_DEFAULT_PROFILE.aws_access_key_id "${AWS_ACCESS_KEY_ID}"
aws configure set profile.$AWS_DEFAULT_PROFILE.aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}"
aws configure set profile.$AWS_DEFAULT_PROFILE.region "${AWS_REGION}"
aws configure set profile.$AWS_DEFAULT_PROFILE.endpoint_url "${AWS_ENDPOINT_URL}"
echo "AWS Profile configured successfully."
echo "-----------------------------------------------------------------"
echo ""

while true; do sleep 1000; done

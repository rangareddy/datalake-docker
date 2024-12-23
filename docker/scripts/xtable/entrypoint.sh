#!/bin/bash
set -e

export XTABLE_HOME=${XTABLE_HOME:-/opt/xtable}
export IS_AWS_ENABLED=${IS_AWS_ENABLED:-true}

if [ "${IS_AWS_ENABLED}" = "true" ]; then

  # Configure AWS Default Profile
  echo "-----------------------------------------------------------------"
  echo "Configuring the AWS Profile..."
  AWS_DEFAULT_PROFILE="default"
  #AWS_ENDPOINT_URL=$(echo "$AWS_ENDPOINT_URL" | sed -E 's|http://([^/]+).*|\1|')

  aws configure set profile $AWS_DEFAULT_PROFILE
  aws configure set profile.$AWS_DEFAULT_PROFILE.aws_access_key_id "${AWS_ACCESS_KEY_ID}"
  aws configure set profile.$AWS_DEFAULT_PROFILE.aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}"
  aws configure set profile.$AWS_DEFAULT_PROFILE.region "${AWS_REGION}"
  aws configure set profile.$AWS_DEFAULT_PROFILE.endpoint_url "${AWS_ENDPOINT_URL}"
  #aws configure set profile.$AWS_DEFAULT_PROFILE.s3.signature_version s3v4
  #aws configure set profile.$AWS_DEFAULT_PROFILE.s3.path.style.access true
  #aws configure set profile.$AWS_DEFAULT_PROFILE.s3.connection.ssl.enabled false
  echo "AWS Profile configured successfully."
  echo "-----------------------------------------------------------------"
  echo ""
fi

while true; do sleep 1000; done

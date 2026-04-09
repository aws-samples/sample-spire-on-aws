#!/usr/bin/env bash
set -euo pipefail

# Upload SPIRE K8s templates to an S3 bucket in the user's account.
# Usage: ./upload-templates.sh [--region REGION] [--bucket BUCKET_NAME]
#
# If --bucket is omitted, creates spire-templates-<ACCOUNT_ID>-<REGION>.
# The bucket name is printed at the end for use with the companion stack.

REGION=""
BUCKET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2"; shift 2 ;;
    --bucket)  BUCKET="$2"; shift 2 ;;
    *)         echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Default region from CLI config
if [[ -z "$REGION" ]]; then
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [[ -z "$BUCKET" ]]; then
  BUCKET="spire-templates-${ACCOUNT_ID}-${REGION}"
fi

echo "Account:  $ACCOUNT_ID"
echo "Region:   $REGION"
echo "Bucket:   $BUCKET"

# Create bucket if it doesn't exist
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Bucket already exists."
else
  echo "Creating bucket $BUCKET..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

# Upload templates
echo "Uploading templates..."
aws s3 sync templates/ "s3://${BUCKET}/templates/" --region "$REGION" --delete

echo ""
echo "Done. Use this bucket name when deploying the companion stack:"
echo "  TemplateBucketName=$BUCKET"

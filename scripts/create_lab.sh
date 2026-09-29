#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_file="$root_dir/.lab-state.env"
region="${AWS_REGION:-ap-southeast-2}"

command -v aws >/dev/null 2>&1 || {
  printf 'The AWS CLI is required.\n' >&2
  exit 1
}

if [[ -f "$state_file" ]]; then
  printf 'Lab state already exists: %s\n' "$state_file" >&2
  printf 'Run cleanup.sh before creating another lab.\n' >&2
  exit 1
fi

suffix="$(date -u +%Y%m%d%H%M%S)-${RANDOM}${RANDOM}"
bucket="${LAB_BUCKET:-s3-60-lab-$suffix}"
bucket_created=0

cleanup_partial_bucket() {
  if [[ "$bucket_created" -eq 1 ]]; then
    aws s3api delete-bucket --bucket "$bucket" >/dev/null 2>&1 || true
  fi
}
trap cleanup_partial_bucket ERR

if [[ ! "$bucket" =~ ^s3-60-lab-[a-z0-9-]+$ ]]; then
  printf 'Bucket name must start with s3-60-lab- and use lowercase letters, digits, or hyphens.\n' >&2
  exit 1
fi

if [[ "$region" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
else
  aws s3api create-bucket \
    --bucket "$bucket" \
    --region "$region" \
    --create-bucket-configuration "LocationConstraint=$region" >/dev/null
fi
bucket_created=1

aws s3api put-public-access-block \
  --bucket "$bucket" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-ownership-controls \
  --bucket "$bucket" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

aws s3api put-bucket-versioning \
  --bucket "$bucket" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$bucket" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'

aws s3api put-bucket-tagging \
  --bucket "$bucket" \
  --tagging 'TagSet=[{Key=Project,Value=s3-60-lab},{Key=ManagedBy,Value=book-companion}]'

umask 077
{
  printf 'LAB_BUCKET=%q\n' "$bucket"
  printf 'AWS_REGION=%q\n' "$region"
} > "$state_file"

trap - ERR

printf 'Created private versioned lab bucket: %s\n' "$bucket"
printf 'State recorded in %s\n' "$state_file"

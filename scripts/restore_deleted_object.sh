#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_file="$root_dir/.lab-state.env"
object_key="${1:-workflow/report.txt}"

if [[ ! "$object_key" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  printf 'Object key contains unsupported characters.\n' >&2
  exit 1
fi

if [[ ! -f "$state_file" ]]; then
  printf 'Missing lab state. Run create_lab.sh first.\n' >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$state_file"
export AWS_REGION

marker_id="$(
  aws s3api list-object-versions \
    --bucket "$LAB_BUCKET" \
    --prefix "$object_key" \
    --query "DeleteMarkers[?Key=='$object_key' && IsLatest].VersionId | [0]" \
    --output text
)"

if [[ -z "$marker_id" || "$marker_id" == "None" ]]; then
  printf 'No current delete marker found for %s.\n' "$object_key" >&2
  exit 1
fi

aws s3api delete-object \
  --bucket "$LAB_BUCKET" \
  --key "$object_key" \
  --version-id "$marker_id" >/dev/null

aws s3api head-object --bucket "$LAB_BUCKET" --key "$object_key" >/dev/null
printf 'Restored the previous current version of %s.\n' "$object_key"

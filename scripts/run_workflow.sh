#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_file="$root_dir/.lab-state.env"
tmp_dir="$root_dir/.tmp"
object_key="workflow/report.txt"

if [[ ! -f "$state_file" ]]; then
  printf 'Missing lab state. Run create_lab.sh first.\n' >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$state_file"
export AWS_REGION
mkdir -p "$tmp_dir"

aws s3 cp "$root_dir/fixtures/original.txt" "s3://$LAB_BUCKET/$object_key"
aws s3api head-object --bucket "$LAB_BUCKET" --key "$object_key" >/dev/null
aws s3 cp "s3://$LAB_BUCKET/$object_key" "$tmp_dir/downloaded-original.txt"
grep -Fxq '2026-Q2,131500' "$tmp_dir/downloaded-original.txt"

presigned_url="$(aws s3 presign "s3://$LAB_BUCKET/$object_key" --expires-in 300)"
curl --fail --silent --show-error "$presigned_url" \
  --output "$tmp_dir/presigned-download.txt"
grep -Fxq '2026-Q2,131500' "$tmp_dir/presigned-download.txt"

aws s3 cp "$root_dir/fixtures/updated.txt" "s3://$LAB_BUCKET/$object_key"
version_count="$(
  aws s3api list-object-versions \
    --bucket "$LAB_BUCKET" \
    --prefix "$object_key" \
    --query 'length(Versions || `[]`)' \
    --output text
)"
if [[ "$version_count" -lt 2 ]]; then
  printf 'Expected at least two object versions; found %s.\n' "$version_count" >&2
  exit 1
fi

aws s3api delete-object --bucket "$LAB_BUCKET" --key "$object_key" >/dev/null
if aws s3api head-object --bucket "$LAB_BUCKET" --key "$object_key" >/dev/null 2>&1; then
  printf 'The simple delete did not hide the current object as expected.\n' >&2
  exit 1
fi

"$root_dir/scripts/restore_deleted_object.sh" "$object_key"
aws s3 cp "s3://$LAB_BUCKET/$object_key" "$tmp_dir/restored.txt"
grep -Fxq '2026-Q2,134250' "$tmp_dir/restored.txt"

printf 'PASS: upload, download, presigned GET, versioning, delete marker, and restore.\n'

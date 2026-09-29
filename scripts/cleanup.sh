#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_file="$root_dir/.lab-state.env"
tmp_dir="$root_dir/.tmp"

if [[ ! -f "$state_file" ]]; then
  printf 'No lab state file exists; nothing to clean.\n'
  exit 0
fi

# shellcheck disable=SC1090
source "$state_file"
export AWS_REGION

if [[ ! "$LAB_BUCKET" =~ ^s3-60-lab-[a-z0-9-]+$ ]]; then
  printf 'Refusing cleanup for unexpected bucket name: %s\n' "$LAB_BUCKET" >&2
  exit 1
fi

project_tag="$(
  aws s3api get-bucket-tagging \
    --bucket "$LAB_BUCKET" \
    --query "TagSet[?Key=='Project'].Value | [0]" \
    --output text
)"
managed_tag="$(
  aws s3api get-bucket-tagging \
    --bucket "$LAB_BUCKET" \
    --query "TagSet[?Key=='ManagedBy'].Value | [0]" \
    --output text
)"
if [[ "$project_tag" != "s3-60-lab" || "$managed_tag" != "book-companion" ]]; then
  printf 'Refusing cleanup because ownership tags do not match.\n' >&2
  exit 1
fi

mkdir -p "$tmp_dir"

delete_versions() {
  local member="$1"
  local payload="$tmp_dir/delete-$member.json"
  local count
  count="$(
    aws s3api list-object-versions \
      --bucket "$LAB_BUCKET" \
      --query "length($member || \`[]\`)" \
      --output text
  )"
  if [[ "$count" -eq 0 ]]; then
    return
  fi
  if [[ "$count" -gt 100 ]]; then
    printf 'Refusing automated cleanup of more than 100 %s.\n' "$member" >&2
    exit 1
  fi
  aws s3api list-object-versions \
    --bucket "$LAB_BUCKET" \
    --query "{Objects: $member[].{Key:Key,VersionId:VersionId}, Quiet: \`true\`}" \
    --output json > "$payload"
  aws s3api delete-objects \
    --bucket "$LAB_BUCKET" \
    --delete "file://$payload" >/dev/null
}

delete_versions Versions
delete_versions DeleteMarkers

remaining_versions="$(
  aws s3api list-object-versions --bucket "$LAB_BUCKET" \
    --query 'length(Versions || `[]`)' --output text
)"
remaining_markers="$(
  aws s3api list-object-versions --bucket "$LAB_BUCKET" \
    --query 'length(DeleteMarkers || `[]`)' --output text
)"
if [[ "$remaining_versions" -ne 0 || "$remaining_markers" -ne 0 ]]; then
  printf 'Cleanup stopped: %s versions and %s delete markers remain.\n' \
    "$remaining_versions" "$remaining_markers" >&2
  exit 1
fi

aws s3api delete-bucket --bucket "$LAB_BUCKET"

if ! aws s3api wait bucket-not-exists --bucket "$LAB_BUCKET"; then
  printf 'Could not verify that the bucket is absent after delete-bucket.\n' >&2
  exit 1
fi

rm -f "$state_file"
printf 'PASS: all versions and delete markers removed; bucket is absent.\n'

#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_file="$root_dir/.lab-state.env"
tmp_dir="$root_dir/.tmp"
combined_limit="${LAB_CLEANUP_MAX_ITEMS:-100}"

if [[ ! -f "$state_file" ]]; then
  printf 'No lab state file exists; nothing to clean.\n'
  exit 0
fi

# shellcheck disable=SC1090
source "$state_file"
export AWS_REGION

# --- Preflight: validate the target and plan the deletion BEFORE deleting anything. ---
# Nothing below this line deletes until the full plan is validated and within the limit.

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

# Inventory both object versions and delete markers up front.
version_count="$(
  aws s3api list-object-versions --bucket "$LAB_BUCKET" \
    --query 'length(Versions || `[]`)' --output text
)"
marker_count="$(
  aws s3api list-object-versions --bucket "$LAB_BUCKET" \
    --query 'length(DeleteMarkers || `[]`)' --output text
)"
total_count=$(( version_count + marker_count ))

# One combined safety brake: refuse an oversized plan without deleting anything.
if (( total_count > combined_limit )); then
  printf 'Refusing automated cleanup: %s object versions + %s delete markers = %s items exceeds the %s-item safety limit. Nothing was deleted.\n' \
    "$version_count" "$marker_count" "$total_count" "$combined_limit" >&2
  exit 1
fi

# --- Execute the approved plan. ---

mkdir -p "$tmp_dir"

delete_member() {
  local member="$1"
  local count="$2"
  if (( count == 0 )); then
    return 0
  fi
  local payload="$tmp_dir/delete-$member.json"
  aws s3api list-object-versions \
    --bucket "$LAB_BUCKET" \
    --query "{Objects: $member[].{Key:Key,VersionId:VersionId}, Quiet: \`true\`}" \
    --output json > "$payload"
  aws s3api delete-objects \
    --bucket "$LAB_BUCKET" \
    --delete "file://$payload" >/dev/null
}

delete_member Versions "$version_count"
delete_member DeleteMarkers "$marker_count"

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
printf 'PASS: preflight approved %s items; all versions and delete markers removed; bucket is absent.\n' "$total_count"

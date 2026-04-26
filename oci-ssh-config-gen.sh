#!/usr/bin/env bash
set -euo pipefail

# oci-ssh-config-gen.sh
# Scans OCI compute instances across a tenancy and emits ~/.ssh/config entries
# grouped by compartment using ### compartment-name ### section headers.

SCRIPT_VERSION="1.0.0"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
OUTPUT_FILE=""

ACTIVE_STATES=("RUNNING" "STOPPED" "STARTING")

# Temp files registered here so the EXIT trap can clean them all up
TMPFILES=()

cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

usage() {
  cat <<EOF
oci-ssh-config-gen.sh v${SCRIPT_VERSION}

Scan OCI compute instances and output SSH config entries grouped by compartment.

Usage:
  oci-ssh-config-gen.sh [OPTIONS]

Options:
  -p, --profile PROFILE   OCI CLI profile name (default: \$OCI_PROFILE or DEFAULT)
  -o, --output FILE       Write output to FILE instead of stdout
  -h, --help              Show this help and exit

Output format:
  ### compartment-name ###

  Host instance-name
      Hostname 10.x.x.x

Environment:
  OCI_PROFILE       Default OCI profile (overridden by -p)
  OCI_CONFIG_FILE   Path to OCI config (default: ~/.oci/config)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile) OCI_PROFILE="$2"; shift 2 ;;
    -o|--output)  OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

command -v oci  &>/dev/null || die "'oci' CLI not found on PATH. Install the OCI CLI first."
command -v jq   &>/dev/null || die "'jq' not found on PATH. Install jq (e.g. yum install jq)."
[[ -f "$OCI_CONFIG_FILE" ]] || die "OCI config not found at '$OCI_CONFIG_FILE'."

if [[ -n "$OUTPUT_FILE" ]]; then
  # Create with strict permissions before writing — SSH config contains private IPs
  (umask 177 && touch "$OUTPUT_FILE") 2>/dev/null || die "Cannot write to output file: $OUTPUT_FILE"
fi

# ---------------------------------------------------------------------------
# Read tenancy OCID from OCI config
# ---------------------------------------------------------------------------

get_tenancy_ocid() {
  local profile="$1"
  awk -v target="[$profile]" '
    /^\[/ { in_section = ($0 == target) }
    in_section && /^tenancy[[:space:]]*=/ {
      sub(/^tenancy[[:space:]]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$OCI_CONFIG_FILE" | tr -d '[:space:]'
}

TENANCY_OCID=$(get_tenancy_ocid "$OCI_PROFILE")
[[ -n "$TENANCY_OCID" ]] || die "Could not find 'tenancy' in profile [$OCI_PROFILE] of $OCI_CONFIG_FILE"

# ---------------------------------------------------------------------------
# OCI API calls
# ---------------------------------------------------------------------------

oci_call() {
  # OCI CLI sends usage/auth errors to stdout (not stderr) when --output json is set,
  # so we capture both and merge them into the warning on failure.
  local out_tmp err_tmp
  out_tmp=$(mktemp); err_tmp=$(mktemp)
  TMPFILES+=("$out_tmp" "$err_tmp")
  if oci "$@" --profile "$OCI_PROFILE" --output json >"$out_tmp" 2>"$err_tmp"; then
    cat "$out_tmp"
  else
    # Redact OCIDs (ocid1.<type>.oc1..<hash>) from the warning to avoid leaking them to logs
    local raw_err
    raw_err=$(cat "$err_tmp" "$out_tmp" | head -5)
    warn "OCI CLI call failed (oci ${1:-} ${2:-} ...): ${raw_err//ocid1.[^[:space:]]*/[OCID REDACTED]}"
    echo '{"data":[]}'
  fi
}

list_compartments() {
  oci_call iam compartment list \
    --compartment-id "$TENANCY_OCID" \
    --all \
    --compartment-id-in-subtree true \
    --access-level ANY \
    --lifecycle-state ACTIVE
}

list_instances() {
  local compartment_id="$1"
  oci_call compute instance list \
    --compartment-id "$compartment_id" \
    --all
}

get_primary_vnic_ip() {
  local instance_id="$1"
  local raw stderr_tmp
  stderr_tmp=$(mktemp)
  TMPFILES+=("$stderr_tmp")
  if raw=$(oci compute instance list-vnics \
      --instance-id "$instance_id" \
      --profile "$OCI_PROFILE" \
      --output json 2>"$stderr_tmp"); then
    jq -r '.data[] | select(."is-primary" == true) | ."private-ip" // empty' <<<"$raw"
  else
    warn "list-vnics failed for instance [OCID REDACTED]: $(cat "$stderr_tmp")"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Build compartment list (root + all children)
# ---------------------------------------------------------------------------

echo "Fetching compartments..." >&2

# Root compartment entry is the tenancy itself; give it the name "root"
ROOT_JSON=$(printf '[{"id":"%s","name":"root"}]' "$TENANCY_OCID")

CHILD_JSON=$(list_compartments | jq '[.data[] | {id: .id, name: .name}]')

# Merge: root first, then children sorted by name
ALL_COMPARTMENTS=$(jq -s '.[0] + (.[1] | sort_by(.name))' \
  <(echo "$ROOT_JSON") \
  <(echo "$CHILD_JSON"))

COMPARTMENT_COUNT=$(jq 'length' <<<"$ALL_COMPARTMENTS")
echo "Found $COMPARTMENT_COUNT compartment(s). Scanning instances..." >&2

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------

# jq filter: keep only active lifecycle states
JQ_STATE_FILTER=$(printf '"%s",' "${ACTIVE_STATES[@]}")
JQ_STATE_FILTER="[${JQ_STATE_FILTER%,}]"

generate_output() {
  local total_instances=0

  for i in $(seq 0 $((COMPARTMENT_COUNT - 1))); do
    local compartment_id compartment_name
    compartment_id=$(jq -r ".[$i].id"   <<<"$ALL_COMPARTMENTS")
    compartment_name=$(jq -r ".[$i].name" <<<"$ALL_COMPARTMENTS")

    local instances_json
    instances_json=$(list_instances "$compartment_id" \
      | jq --argjson states "$JQ_STATE_FILTER" \
           '[.data[] | select(.["lifecycle-state"] as $s | $states | index($s) != null)]')

    local count
    count=$(jq 'length' <<<"$instances_json")
    [[ "$count" -eq 0 ]] && continue

    echo "### ${compartment_name} ###"
    echo ""

    for j in $(seq 0 $((count - 1))); do
      local display_name instance_id
      display_name=$(jq -r ".[$j][\"display-name\"]" <<<"$instances_json")
      instance_id=$(jq -r ".[$j].id" <<<"$instances_json")

      # Sanitize: replace any char unsafe in SSH Host aliases with hyphens,
      # collapse runs, strip leading/trailing hyphens
      local host_alias
      host_alias=$(echo "$display_name" \
        | sed 's/[^A-Za-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')

      local private_ip
      private_ip=$(get_primary_vnic_ip "$instance_id")

      if [[ -z "$private_ip" ]]; then
        warn "No primary VNIC private IP for instance '$display_name' — skipped."
        continue
      fi

      echo "Host ${host_alias}"
      echo "    Hostname ${private_ip}"
      echo ""

      total_instances=$((total_instances + 1))
    done

  done

  echo "Done. $total_instances instance(s) written." >&2
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

if [[ -n "$OUTPUT_FILE" ]]; then
  generate_output > "$OUTPUT_FILE"
  echo "Output written to: $OUTPUT_FILE" >&2
else
  generate_output
fi

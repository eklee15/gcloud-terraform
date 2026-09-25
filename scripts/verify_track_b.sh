#!/usr/bin/env bash
# End-to-end smoke test for Track B (ansible/vpc.tf + packages.yaml).
#
# Prerequisites:
#   - gcloud, terraform, ansible-playbook, ssh, Python 3
#   - ansible/key.json service-account key with Compute permissions
#   - Real values for SSH_USER, SSH_PUBLIC_KEY, SSH_PRIVATE_KEY (or edit vpc.tf)
#   - GCP_PROJECT
#
# Usage:
#   export GCP_PROJECT=your-project-id
#   export SSH_USER=$(whoami)
#   export SSH_PUBLIC_KEY=$HOME/.ssh/id_rsa.pub
#   export SSH_PRIVATE_KEY=$HOME/.ssh/id_rsa
#   # place key.json in ansible/ OR set GOOGLE_APPLICATION_CREDENTIALS and
#   # copy/symlink to ansible/key.json (vpc.tf hard-requires file("key.json"))
#   ./scripts/verify_track_b.sh
#
# Env:
#   SKIP_DESTROY=1  leave the VM up
#   KEEP_WORKDIR=1  keep temp dir

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_SRC="$ROOT/ansible"
ZONE="us-east4-a"
INSTANCE="example-instance"
WORKDIR=""
APPLY_ATTEMPTED=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_terraform() {
  if ! command -v terraform >/dev/null 2>&1; then
    die "Terraform is not installed or not on PATH.
Install Terraform >= 1.x (https://developer.hashicorp.com/terraform/install), then re-run.
macOS (Homebrew): brew tap hashicorp/tap && brew install hashicorp/tap/terraform"
  fi
  local ver
  ver="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$ver" ]]; then
    ver="$(terraform version | head -1 | awk '{print $2}' | sed 's/^v//')"
  fi
  log "Terraform $ver ($(command -v terraform))"
  local major="${ver%%.*}"
  [[ -n "$major" && "$major" -ge 1 ]] || die "Terraform >= 1.x required (found: ${ver:-unknown})"
}

cleanup() {
  local ec=$?
  if [[ "$APPLY_ATTEMPTED" -eq 1 && "${SKIP_DESTROY:-0}" != "1" && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    log "destroying Track B resources in $WORKDIR"
    (cd "$WORKDIR" && terraform destroy -auto-approve -input=false) || {
      echo "WARNING: terraform destroy failed; check project ${GCP_PROJECT:-?}" >&2
      ec=1
    }
  elif [[ "$APPLY_ATTEMPTED" -eq 1 && "${SKIP_DESTROY:-0}" == "1" ]]; then
    echo "WARNING: SKIP_DESTROY=1; resources still running in $WORKDIR" >&2
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" && "${KEEP_WORKDIR:-0}" != "1" && "${SKIP_DESTROY:-0}" != "1" ]]; then
    rm -rf "$WORKDIR"
  fi
  exit "$ec"
}
trap cleanup EXIT

log "checking Terraform"
require_terraform
need_cmd ansible-playbook
need_cmd gcloud
need_cmd python3
need_cmd ssh

GCP_PROJECT="${GCP_PROJECT:-}"
[[ -n "$GCP_PROJECT" ]] || die "set GCP_PROJECT"

SSH_USER="${SSH_USER:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
[[ -n "$SSH_USER" ]] || die "set SSH_USER (Linux username injected via instance metadata)"
[[ -n "$SSH_PUBLIC_KEY" && -f "$SSH_PUBLIC_KEY" ]] || die "set SSH_PUBLIC_KEY to an existing .pub file"
[[ -n "$SSH_PRIVATE_KEY" && -f "$SSH_PRIVATE_KEY" ]] || die "set SSH_PRIVATE_KEY to an existing private key file"

KEY_JSON="${KEY_JSON:-$ANSIBLE_SRC/key.json}"
[[ -f "$KEY_JSON" ]] || die "missing service-account key at $KEY_JSON (vpc.tf uses file(\"key.json\"))"

# The script changes into a temporary directory; make user-supplied paths
# absolute before passing them to Terraform, Ansible, and ssh.
SSH_PUBLIC_KEY="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SSH_PUBLIC_KEY")"
SSH_PRIVATE_KEY="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SSH_PRIVATE_KEY")"
KEY_JSON="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$KEY_JSON")"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gcloud-tf-verify-b.XXXXXX")"
log "workdir $WORKDIR"
cp "$ANSIBLE_SRC/vpc.tf" "$ANSIBLE_SRC/clusterinventory.tpl" "$ANSIBLE_SRC/packages.yaml" "$WORKDIR/"
cp "$KEY_JSON" "$WORKDIR/key.json"
chmod 600 "$WORKDIR/key.json"

# Keep service-account authentication isolated from the user's gcloud config.
export CLOUDSDK_CONFIG="$WORKDIR/gcloud"
mkdir -m 700 "$CLOUDSDK_CONFIG"
gcloud auth activate-service-account \
  --key-file="$WORKDIR/key.json" --project="$GCP_PROJECT" --quiet >/dev/null

# Rewrite only the provider project. SSH variables are passed through TF_VAR_*
# so paths and usernames do not need HCL string escaping.
python3 - "$WORKDIR/vpc.tf" "$GCP_PROJECT" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
project = sys.argv[2]
text = path.read_text()
placeholder = '<YOUR GCP PROJECT NAME>'
if placeholder not in text:
    raise SystemExit(f"project placeholder not found in vpc.tf: {placeholder}")
text = text.replace(placeholder, project, 1)
path.write_text(text)
PY

export TF_VAR_ssh_key="$SSH_PUBLIC_KEY"
export TF_VAR_ssh_private_key="$SSH_PRIVATE_KEY"
export TF_VAR_ssh_user="$SSH_USER"

cd "$WORKDIR"
log "terraform init"
terraform init -input=false
log "terraform validate"
terraform validate
log "terraform apply"
APPLY_ATTEMPTED=1
terraform apply -auto-approve -input=false

[[ -f cluster.inventory ]] || die "cluster.inventory was not written"
FIP="$(terraform output -raw instance_fip)"
log "instance_fip=$FIP"

log "retrieving trusted SSH host keys through the Compute Engine API"
HOST_KEYS_JSON="$WORKDIR/hostkeys.json"
KNOWN_HOSTS="$WORKDIR/known_hosts"
host_keys_ready=0
for ((i = 1; i <= 40; i++)); do
  if gcloud compute instances get-guest-attributes "$INSTANCE" \
      --project="$GCP_PROJECT" --zone="$ZONE" --query-path='hostkeys/' \
      --format=json >"$HOST_KEYS_JSON" 2>/dev/null \
    && python3 - "$HOST_KEYS_JSON" "$FIP" >"$KNOWN_HOSTS.tmp" <<'PY'
import json
import sys

entries = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(entries, dict):
    entries = [entries]
host = sys.argv[2]
for entry in entries:
    algorithm = entry.get("key", "")
    key = entry.get("value", "")
    if (algorithm.startswith("ssh-") or algorithm.startswith("ecdsa-")) and key:
        print(f"{host} {algorithm} {key}")
PY
  then
    if [[ -s "$KNOWN_HOSTS.tmp" ]]; then
      mv "$KNOWN_HOSTS.tmp" "$KNOWN_HOSTS"
      chmod 600 "$KNOWN_HOSTS"
      host_keys_ready=1
      break
    fi
  fi
  rm -f "$KNOWN_HOSTS.tmp"
  sleep 5
done
[[ "$host_keys_ready" -eq 1 ]] \
  || die "VM did not publish SSH host keys through guest attributes"

log "waiting for SSH on $FIP"
ready=0
for ((i = 1; i <= 40; i++)); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$KNOWN_HOSTS" -o IdentitiesOnly=yes \
      -o ConnectTimeout=5 -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${FIP}" true 2>/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
[[ "$ready" -eq 1 ]] \
  || die "SSH to $FIP never succeeded; Track B relies on the default VPC and an existing rule allowing TCP/22"

log "ansible-playbook packages.yaml"
ANSIBLE_HOST_KEY_CHECKING=True ansible-playbook \
  --private-key "$SSH_PRIVATE_KEY" \
  --ssh-common-args "-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o IdentitiesOnly=yes" \
  -i cluster.inventory packages.yaml

log "verifying packages on host"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS" -o IdentitiesOnly=yes \
  -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${FIP}" \
  'command -v wget && command -v iperf3 && command -v iperf'

log "PASS: Track B packages installed on $FIP"
exit 0

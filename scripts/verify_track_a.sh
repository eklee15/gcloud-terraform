#!/usr/bin/env bash
# End-to-end smoke test for Track A (main.tf + app.py) against a real GCP project.
#
# Prerequisites:
#   - gcloud CLI, Terraform >= 1.x
#   - gcloud auth application-default login
#   - gcloud auth login (for compute ssh/scp)
#   - Compute Engine API enabled on the project
#   - Billing enabled; f1-micro quota in us-east4
#
# Usage:
#   export GCP_PROJECT=your-project-id   # or: gcloud config set project ...
#   ./scripts/verify_track_a.sh
#
# Env:
#   GCP_PROJECT     required unless set in gcloud config
#   SKIP_DESTROY=1  leave resources up after a successful verify (you must destroy)
#   KEEP_WORKDIR=1  keep the temp Terraform directory for debugging
#   CURL_RETRIES    default 30 (2s apart)
#   SSH_RETRIES     default 40 (5s apart)
#
# Exit 0 only if GET Web-server-URL returns "Hello Cloud!" and (unless SKIP_DESTROY)
# terraform destroy succeeds.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZONE="${ZONE:-us-east4-a}"
INSTANCE="${INSTANCE:-flask-vm}"
CURL_RETRIES="${CURL_RETRIES:-30}"
SSH_RETRIES="${SSH_RETRIES:-40}"
WORKDIR=""
APPLY_ATTEMPTED=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Fail fast on Terraform before any GCP auth/project checks.
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
    log "destroying Track A resources in $WORKDIR"
    (cd "$WORKDIR" && terraform destroy -auto-approve -input=false) || {
      echo "WARNING: terraform destroy failed; resources may still be running in project ${GCP_PROJECT:-?} zone $ZONE" >&2
      ec=1
    }
  elif [[ "$APPLY_ATTEMPTED" -eq 1 && "${SKIP_DESTROY:-0}" == "1" ]]; then
    echo "WARNING: SKIP_DESTROY=1 set; VM/network still running. Run terraform destroy in $WORKDIR" >&2
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" && "${KEEP_WORKDIR:-0}" != "1" && "${SKIP_DESTROY:-0}" != "1" ]]; then
    rm -rf "$WORKDIR"
  fi
  exit "$ec"
}
trap cleanup EXIT

log "checking Terraform"
require_terraform

need_cmd curl
need_cmd gcloud

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
[[ -n "${GCP_PROJECT}" && "${GCP_PROJECT}" != "(unset)" ]] \
  || die "set GCP_PROJECT or: gcloud config set project YOUR_PROJECT_ID"

log "checking Application Default Credentials (required by the Google Terraform provider)"
gcloud auth application-default print-access-token >/dev/null \
  || die "ADC missing; run: gcloud auth application-default login"

log "checking gcloud user credentials (needed for compute ssh/scp)"
gcloud auth print-access-token >/dev/null \
  || die "gcloud user auth missing; run: gcloud auth login"

log "using project $GCP_PROJECT"

log "checking project, zone, and Compute Engine API access"
gcloud compute zones describe "$ZONE" --project="$GCP_PROJECT" --quiet >/dev/null \
  || die "cannot access Compute Engine in $GCP_PROJECT/$ZONE; check the project, API, IAM, billing, and quota"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gcloud-tf-verify.XXXXXX")"
log "workdir $WORKDIR"
cp "$ROOT/main.tf" "$ROOT/app.py" "$WORKDIR/"
# Inject real project without editing the repo copy of main.tf
if grep -q 'YOUR_PROJECT_ID' "$WORKDIR/main.tf"; then
  sed -i.bak "s/YOUR_PROJECT_ID/${GCP_PROJECT}/g" "$WORKDIR/main.tf"
  rm -f "$WORKDIR/main.tf.bak"
fi

cd "$WORKDIR"
log "terraform init"
terraform init -input=false

log "terraform validate"
terraform validate

log "terraform apply"
APPLY_ATTEMPTED=1
terraform apply -auto-approve -input=false

URL="$(terraform output -raw Web-server-URL)"
[[ -n "$URL" ]] || die "empty Web-server-URL output"
log "Web-server-URL=$URL"

log "waiting for SSH to $INSTANCE ($ZONE)"
ready=0
for ((i = 1; i <= SSH_RETRIES; i++)); do
  if gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$GCP_PROJECT" \
      --strict-host-key-checking=yes --command="true" --quiet 2>/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
[[ "$ready" -eq 1 ]] || die "SSH never became ready after $SSH_RETRIES attempts"

log "waiting for Flask package (startup script)"
flask_ok=0
for ((i = 1; i <= SSH_RETRIES; i++)); do
  if gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$GCP_PROJECT" \
      --strict-host-key-checking=yes \
      --command="python3 -c 'import flask'" --quiet 2>/dev/null; then
    flask_ok=1
    break
  fi
  sleep 5
done
[[ "$flask_ok" -eq 1 ]] || die "Flask never importable on VM (startup script may have failed)"

log "deploying and starting app.py (not done by Terraform)"
deploy_ok=0
for ((i = 1; i <= 5; i++)); do
  if gcloud compute scp "$WORKDIR/app.py" "${INSTANCE}:~/app.py" \
      --zone="$ZONE" --project="$GCP_PROJECT" \
      --strict-host-key-checking=yes --quiet \
    && gcloud compute ssh "$INSTANCE" \
      --zone="$ZONE" --project="$GCP_PROJECT" \
      --strict-host-key-checking=yes --quiet \
      --command='sudo systemd-run --collect --unit="flask-app-verify-$(date +%s)" --property="WorkingDirectory=$HOME" /usr/bin/python3 "$HOME/app.py"'; then
    deploy_ok=1
    break
  fi
  sleep 5
done
[[ "$deploy_ok" -eq 1 ]] || die "could not deploy and start app.py after 5 attempts"

log "curling $URL until Hello Cloud!"
body=""
for ((i = 1; i <= CURL_RETRIES; i++)); do
  if body="$(curl -fsS --max-time 5 "$URL" 2>/dev/null)"; then
    if [[ "$body" == "Hello Cloud!" ]]; then
      log "PASS: $URL -> Hello Cloud!"
      exit 0
    fi
  fi
  sleep 2
done

echo "Last body: ${body:-<empty>}" >&2
die "FAIL: did not receive Hello Cloud! from $URL"

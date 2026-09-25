# gcloud-terraform

Deploy a Flask web application on Google Cloud Platform using Terraform.

## Overview

This configuration provisions the following GCP resources:

- **Custom VPC network** (`my-custom-mode-network`) with a subnet in `us-east4` (`10.0.1.0/24`)
- **Compute Engine instance** (`flask-vm`, `f1-micro`, Debian 11) with Flask installed via startup script
- **Firewall rules** — SSH (port 22) and Flask app (port 5000) open to `0.0.0.0/0`

The VM URL is exposed as a Terraform output once provisioned.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- A GCP project with the Compute Engine API enabled
- GCP credentials configured (via `gcloud auth application-default login` or a service account)

## Configuration

In [main.tf](main.tf), replace the placeholder with your GCP project ID:

```hcl
provider "google" {
  project = "YOUR_PROJECT_ID"   # <-- replace this
  region  = "us-east4"
}
```

## Usage

**1. Initialize Terraform** (downloads the Google provider plugin):

```bash
terraform init
```

**2. Preview the changes** before applying:

```bash
terraform plan
```

**3. Apply** to create all resources on GCP:

```bash
terraform apply
```

Type `yes` when prompted. When complete, Terraform prints the Flask app URL:

```
Outputs:

Web-server-URL = "http://<EXTERNAL_IP>:5000"
```

> The VM startup script installs Flask automatically. Allow ~1–2 minutes after `apply` finishes before the app is reachable.

**4. Destroy** all resources when done:

```bash
terraform destroy
```

## Resources Created

| Resource | Name | Details |
|---|---|---|
| VPC Network | `my-custom-mode-network` | Custom mode, MTU 1460 |
| Subnet | `my-custom-subnet` | `10.0.1.0/24`, `us-east4` |
| VM Instance | `flask-vm` | `f1-micro`, `us-east4-a`, Debian 11 |
| Firewall | `allow-ssh` | TCP 22 ingress |
| Firewall | `flask-app-firewall` | TCP 5000 ingress |

## Application

The Flask app ([app.py](app.py)) is deployed separately onto the VM. It serves a single route:

```
GET / → "Hello Cloud!"
```

To run it on the VM after SSH-ing in:

```bash
python3 app.py
```

---

## Additional lab material (Track B, verify scripts, setup notes)

The sections above cover the root Terraform + Flask path (`main.tf` / `app.py`). This repository also contains an independent Ansible track under `ansible/`. Do not mix resources from the two tracks unless you intentionally redesign the stack.

> Compatibility update: both Terraform stacks now use supported Debian 12 images. The original overview above is preserved verbatim, so its Debian 11 reference is historical.

### Repository map

| Path | Purpose |
|------|---------|
| [`main.tf`](main.tf) | Custom VPC, subnet, firewall, Debian VM, Flask via startup script (documented above) |
| [`app.py`](app.py) | Flask app: `GET /` returns `Hello Cloud!` |
| [`ansible/vpc.tf`](ansible/vpc.tf) | Alternate stack: VM on the default network, static IP, SSH metadata, inventory file |
| [`ansible/clusterinventory.tpl`](ansible/clusterinventory.tpl) | Template rendered to `cluster.inventory` |
| [`ansible/packages.yaml`](ansible/packages.yaml) | Ansible playbook: install `wget`, `iperf`, `iperf3` |
| [`scripts/verify_track_a.sh`](scripts/verify_track_a.sh) | End-to-end smoke test for the root stack (Terraform + GCP) |
| [`scripts/verify_track_b.sh`](scripts/verify_track_b.sh) | End-to-end smoke test for the Ansible track |
| [`known_issues.txt`](known_issues.txt) | Secondary defects / redundancies (staff reference) |

### Architecture (both tracks)

```text
Root stack (main.tf) — documented above
  Terraform → custom VPC + subnet (10.0.1.0/24, us-east4)
           → firewall: TCP 22 (tag ssh), TCP 5000
           → f1-micro VM (debian-12), startup: install Flask
           → output Web-server-URL = http://<EXTERNAL_IP>:5000
  You still must copy and run app.py on the VM.

Track B (ansible/)
  Terraform → static external IP
           → n1-standard-1 VM (debian-12) on default VPC
           → SSH public key in instance metadata
           → write cluster.inventory
  Ansible  → apt install wget, iperf, iperf3
```

Both tracks use `us-east4` / `us-east4-a`. They differ in machine type, OS image, network model, and post-provisioning.

### Track B — Terraform inventory + Ansible

#### Placeholders in `ansible/vpc.tf`

| Placeholder | File |
|-------------|------|
| `<YOUR GCP PROJECT NAME>` | `ansible/vpc.tf` |
| `<YOUR HOME DIR>/.ssh/id_rsa` and `.pub` | `ansible/vpc.tf` |
| `<YOUR ID on VM>` | `ansible/vpc.tf` |
| `key.json` (service-account key path) | `ansible/vpc.tf` (`credentials = file("key.json")`) |

#### Apply infrastructure

```bash
cd ansible
# place service-account JSON as key.json (do not commit it)
# set ssh_key, ssh_private_key, ssh_user, and project in vpc.tf
terraform init
terraform apply
cat cluster.inventory
```

Outputs: `instance_ip` (private), `instance_fip` (public). Inventory group `[server]` uses the public IP.

#### Configure the host

```bash
ansible-playbook -i cluster.inventory packages.yaml
```

#### Tear down

```bash
terraform destroy
```

### Extra prerequisites for Track B / verify scripts

- Python 3 and `pip` (local Flask checks)
- Ansible (Track B only)
- SSH keypair (Track B only)
- `gcloud` CLI (both verify scripts; SSH/SCP and trusted host-key retrieval)
- Track B: service-account key at `ansible/key.json` (required by the current provider block)

Ordinary `gcloud auth login` alone is not enough for the Google Terraform provider on the root stack — use Application Default Credentials (`gcloud auth application-default login`) as already noted under Prerequisites above.

### Local Flask check (no GCP)

```bash
pip install flask
python3 app.py
curl http://127.0.0.1:5000/
```

### Setup gotchas (read before apply)

- Replace every placeholder in `main.tf` / `ansible/vpc.tf` with real project IDs and SSH paths, or `plan`/`apply` will fail.
- Track B expects a service-account key at `ansible/key.json`.
- The root stack installs Flask on the VM but does not copy or start `app.py`. After apply, SSH in, deploy `app.py`, and run it before curling `Web-server-URL`.
- The root stack does not set `ssh-keys` metadata. Use `gcloud compute ssh flask-vm --zone=us-east4-a` (or configure OS Login / project keys) to reach the instance.

### Automated verify (Terraform + GCP)

Requires **Terraform ≥ 1.x** on `PATH`, then GCP credentials as in Prerequisites, and a project with billing + Compute Engine enabled.

**Root stack (Track A):**

```bash
# install Terraform if needed, e.g. macOS:
#   brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version   # confirm >= 1.x
export GCP_PROJECT=your-project-id
./scripts/verify_track_a.sh
```

Checks Terraform first (install + version), then GCP credentials. Copies `main.tf` into a temp dir (injects your project ID), runs `terraform init` / `validate` / `apply`, obtains the VM host key through authenticated guest attributes, waits for SSH and the Flask package, SCPs and starts `app.py`, curls `Web-server-URL` for `Hello Cloud!`, then `terraform destroy` (unless `SKIP_DESTROY=1`).

**Track B:**

```bash
terraform version
export GCP_PROJECT=your-project-id
export SSH_USER=your_linux_username
export SSH_PUBLIC_KEY=$HOME/.ssh/id_rsa.pub
export SSH_PRIVATE_KEY=$HOME/.ssh/id_rsa
# ansible/key.json must exist (service-account key)
./scripts/verify_track_b.sh
```

Checks Terraform first, then applies Track B, obtains the VM host keys from guest attributes through an isolated service-account-backed `gcloud` configuration, requires strict host-key checking for SSH and Ansible, runs `packages.yaml`, checks `wget` / `iperf` / `iperf3`, then destroys (unless `SKIP_DESTROY=1`).

Track B uses GCP's `default` VPC but does not create an SSH firewall rule. Its live verification therefore also requires the default network and a rule allowing TCP/22 to the VM.

### Cost and safety

- Root stack (`f1-micro`) is inexpensive; Track B (`n1-standard-1` + reserved IP) costs more if left running. Always `terraform destroy` when finished.
- Firewall rules allow ingress from `0.0.0.0/0`. Restrict sources for anything beyond a short-lived lab.
- Never commit `key.json`, `*.tfstate*`, or `.terraform/`.

### Track B resources created

| Resource | Details |
|----------|---------|
| `google_compute_address` | `example-ip` |
| `google_compute_instance` | `example-instance`, `n1-standard-1`, debian-12, default network |
| `local_file` | `cluster.inventory` |
| Outputs | `instance_ip`, `instance_fip` |

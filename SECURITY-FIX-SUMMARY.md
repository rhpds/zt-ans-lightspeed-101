# Security Fix: Replace Hardcoded Password

## What Changed

The demo previously had `ansible123!` hardcoded in ~30 places across 12 files. Every deployment used the same password. This change replaces it with a randomly generated `common_password` provided by the platform.

### Files Modified

| File | Change |
|------|--------|
| `setup-automation/main.yml` | Added password change play, reads `COMMON_PASSWORD` env var |
| `setup-automation/setup-vscode.sh` | Uses `$COMMON_PASSWORD` for controller, inventories, docs; katello facts + satellite script support |
| `setup-automation/setup-control.sh` | Uses `$COMMON_PASSWORD` for controller, sshpass, inventories |
| `config/instances.yaml` | Uses `{{ common_password }}` (templated by platform) |
| `content/antora.yml` | Added `lab_password` and `ssh_password` attributes with `%common_password%` placeholder |
| `content/modules/ROOT/pages/module-{01-06}.adoc` | Uses `{lab_password}` Antora attribute |
| `www/modules/module-{01,02,04}.html` | Uses `%common_password%` placeholder |

## How the Password Flows

```
agnosticv (ansiblebu_password.yaml)
  └── ansiblebu_rhel_password (vault-encrypted)
        └── common_password: "{{ ansiblebu_rhel_password }}"
              │
              ├── instances.yaml: password: {{ common_password }}
              │     └── cloud-init sets rhel user password at VM creation
              │        (currently broken, so main.yml overrides it)
              │
              ├── deploy-showroom-helm-zerotouch.yaml
              │     └── release_values.common_password → COMMON_PASSWORD env var
              │           └── main.yml reads it via lookup('env', 'COMMON_PASSWORD')
              │
              └── _showroom_user_data.bastion_ssh_password
                    └── BASTION_PASSWORD env var (fallback)
```

### main.yml Play Sequence

1. **Create inventory** — Connects to VMs using the image-baked password (`ansible123!`, overridable via `image_password` extra var)
2. **Change VM passwords** — SSHes in with the image password, runs `chpasswd` to set `common_password`, updates `ansible_ssh_pass` for subsequent plays
3. **Run setup scripts** — Copies and executes setup scripts with `COMMON_PASSWORD`, `GUID`, `SATELLITE_SCRIPT`, etc. as environment variables

## How Documentation Gets the Password

1. Adoc source files use `{lab_password}` (Antora attribute syntax)
2. `content/antora.yml` defines `lab_password: "%common_password%"`
3. At deploy time, `setup-vscode.sh` runs:
   - `sed` on `antora.yml` to replace `%common_password%` with the actual value
   - `sed` on HTML/adoc files as a fallback
4. When showroom rebuilds the site with Antora, the attribute resolves to the real password

## Satellite Registration

The setup script supports two modes:

- **`SATELLITE_SCRIPT`** — If set, executes the provided script (used for custom registration)
- **`SATELLITE_URL`** — Falls back to the original katello cert + subscription-manager flow
- Neither set — Skips registration with a warning

Katello facts (`/etc/rhsm/facts/katello.facts`) are written before registration with a randomized `network.fqdn` based on hostname, GUID, and timestamp.

## How to Add New Variables to Zero Touch

Adding a new variable that needs to reach `setup-automation/main.yml` requires changes in three repos:

### 1. Define the variable in agnosticv

In the component config (e.g. `zt-ansiblebu/zt-ans-bu-lab-developer-cnv/common.yaml`):

```yaml
my_new_var: "{{ some_source }}"
```

If it's a secret, create an include file in `/includes/secrets/` and reference it:

```yaml
#include /includes/secrets/my_secret.yaml
```

### 2. Pass it through the showroom helm chart

In `agnosticd/ansible/roles_ocp_workloads/ocp4_workload_showroom/tasks/deploy-showroom-helm-zerotouch.yaml`, add it to `release_values`:

```yaml
release_values:
  my_new_var: "{{ my_new_var | default('') }}"
```

The helm chart converts release values into environment variables in the ansible-runner container. The naming convention is uppercase (e.g. `my_new_var` → `MY_NEW_VAR`).

### 3. Read it in main.yml

In `setup-automation/main.yml`, read it from the environment:

```yaml
environment:
  MY_NEW_VAR: "{{ lookup('ansible.builtin.env', 'MY_NEW_VAR', default='') }}"
```

Then use `$MY_NEW_VAR` in the setup scripts.

### Variable Flow Diagram

```
agnosticv component config
  → deployer variables
    → deploy-showroom-helm-zerotouch.yaml release_values
      → helm chart templates
        → env vars in ansible-runner pod
          → main.yml lookup('env', ...)
            → environment block
              → setup scripts ($VAR)
```

### Existing Variables and Their Sources

| Variable | Source | Env Var |
|----------|--------|---------|
| `common_password` | `ansiblebu_rhel_password` (vault) | `COMMON_PASSWORD` (+ `BASTION_PASSWORD` fallback) |
| `satellite_url` | `demosat-rhel-8-and-9-latest.yaml` include | `SATELLITE_URL` |
| `satellite_org` | Same include | `SATELLITE_ORG` |
| `satellite_activationkey` | Same include (vault) | `SATELLITE_ACTIVATIONKEY` |
| `satellite_script` | `satellite_script.yaml` include (vault) | `SATELLITE_SCRIPT` |
| `guid` | Platform-generated | `GUID` |
| Cloud credentials | Sandbox provision data | `AWS_*`, `AZURE_*` |
| Registry credentials | `secrets.yaml` (vault) | `QUAY_USERNAME`, `QUAY_PASSWORD` |

## Repos Involved

| Repo | Branch | Changes |
|------|--------|---------|
| `rhpds/zt-ans-lightspeed-101` | `security-fix` | All password, satellite, katello changes |
| `redhat-cop/agnosticd` | `showroom-security-fix` | Added `common_password` and `satellite.script` to helm release values |
| `rhpds/zt-ansiblebu-agnosticv` | (may need update) | Add `#include /includes/secrets/satellite_script.yaml` to component config |

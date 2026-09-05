#!/usr/bin/env bash
# =============================================================================
# TechSprint - the one script
#
# "Skripta mora primati putanju do .csv datoteke kako bi automatski kreirala
#  infrastrukturu za varijabilni broj korisnika."
# "Skripta se pokreće jednom, ne pokreće se više skripti."
#
#   ./deploy.sh --csv users.example.csv --cloud azure
#   ./deploy.sh --csv users.example.csv --cloud openstack
#   ./deploy.sh --csv users.example.csv --cloud both
#
#   ./deploy.sh --csv users.example.csv --cloud azure --plan-only
#   ./deploy.sh --csv users.example.csv --cloud azure --destroy
#
# Everything between reading the CSV and a working Moodle happens here: parse,
# validate, terraform apply, render the Ansible inventory from the outputs,
# run Ansible, verify. No intermediate step is performed by hand, which is what
# the "one script" requirement means and what the demo video has to show.
# =============================================================================

set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_ROOT/build"
START_TIME=$SECONDS

# --- output ------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_STEP=$'\033[1;36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s[%d] %s%s\n' "$C_STEP" "$STEP_NO" "$*" "$C_RESET"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '\n%sfail%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }
hint() { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

usage() {
  cat <<'USAGE'
TechSprint deployment - one script, one run, any number of users.

  ./deploy.sh --csv <path> --cloud <azure|openstack|both> [options]

Required:
  --cloud <target>   azure, openstack, or both

Required unless --destroy:
  --csv <path>       Users file in the brief's format: ime;prezime;rola
                     Roles: developer, devops_lead. See users.example.csv

Options:
  --plan-only        Show the Terraform plan and stop. Creates nothing.
  --destroy          Tear the environment down.
  --skip-ansible     Build infrastructure but do not install Moodle.
  --yes, -y          Do not prompt before applying. Use for the demo recording.
  -h, --help         This text.

Examples:
  ./deploy.sh --csv users.example.csv --cloud azure --plan-only
  ./deploy.sh --csv users.example.csv --cloud both --yes
  ./deploy.sh --csv users.example.csv --cloud azure --destroy

What it does, in order: parse and validate the CSV, terraform apply, render the
Ansible inventory from the Terraform outputs, run Ansible, verify. No step in
between is performed by hand - that is what the brief's "skripta se pokrece
jednom, ne pokrece se vise skripti" requires, and what the video must show.
USAGE
  exit "${1:-0}"
}

# --- arguments ---------------------------------------------------------------
CSV_PATH=""
CLOUD=""
PLAN_ONLY=0
DESTROY=0
SKIP_ANSIBLE=0
AUTO_APPROVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)          CSV_PATH="${2:-}"; shift 2 ;;
    --cloud)        CLOUD="${2:-}"; shift 2 ;;
    --plan-only)    PLAN_ONLY=1; shift ;;
    --destroy)      DESTROY=1; shift ;;
    --skip-ansible) SKIP_ANSIBLE=1; shift ;;
    --yes|-y)       AUTO_APPROVE=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              printf 'unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
  esac
done

[[ -n "$CLOUD" ]]    || { printf 'missing --cloud\n\n' >&2; usage 2; }
((PLAN_ONLY == 0 || DESTROY == 0)) || die "--plan-only and --destroy cannot be used together"
if ((DESTROY == 0)); then
  [[ -n "$CSV_PATH" ]] || { printf 'missing --csv\n\n' >&2; usage 2; }
  [[ -f "$CSV_PATH" ]] || die "CSV not found: $CSV_PATH"
elif [[ -n "$CSV_PATH" && ! -f "$CSV_PATH" ]]; then
  die "CSV not found: $CSV_PATH"
fi

case "$CLOUD" in
  azure|openstack|both) ;;
  *) die "--cloud must be azure, openstack or both (got '$CLOUD')" ;;
esac

CLOUDS=()
[[ "$CLOUD" == "azure"     || "$CLOUD" == "both" ]] && CLOUDS+=(azure)
[[ "$CLOUD" == "openstack" || "$CLOUD" == "both" ]] && CLOUDS+=(openstack)

# shellcheck source=lib/deploy_openstack.sh
source "$REPO_ROOT/lib/deploy_openstack.sh"

# =============================================================================
# 1. Preflight
# =============================================================================
step "Preflight: tooling and credentials"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. See docs/setup.md#prerequisites"
}

require_cmd terraform
require_cmd python3
require_cmd ssh
ok "terraform $(terraform version -json | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])')"
ok "python3 $(python3 -c 'import platform; print(platform.python_version())')"

if ((SKIP_ANSIBLE == 0)) && ((PLAN_ONLY == 0)) && ((DESTROY == 0)); then
  require_cmd ansible-playbook
  ok "ansible $(ansible-playbook --version | head -1 | awk '{print $NF}' | tr -d ']')"
fi

for cloud in "${CLOUDS[@]}"; do
  case "$cloud" in
    azure)
      require_cmd az
      az account show >/dev/null 2>&1 || die "not logged in to Azure. Run: az login"
      sub_name="$(az account show --query name -o tsv | tr -d '\r')"
      ok "Azure: $sub_name"
      if ((DESTROY == 0)); then
        for provider in Microsoft.Compute Microsoft.Network Microsoft.Storage \
                        Microsoft.ManagedIdentity Microsoft.Authorization; do
          registration_state="$(
            az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null |
              tr -d '\r' || true
          )"
          [[ "$registration_state" == "Registered" ]] \
            || die "Azure provider $provider is not registered (state: ${registration_state:-unknown})"
        done
      fi
      if ((DESTROY == 0 && PLAN_ONLY == 0)); then
        rocky_terms="$(az vm image terms show \
          --urn resf:rockylinux-x86_64:9-base:latest \
          --query accepted -o tsv 2>/dev/null | tr -d '\r' || true)"
        [[ "$rocky_terms" == "true" ]] || die "Rocky Linux Marketplace terms are not accepted.
       Review and accept them explicitly before deployment:
       az vm image terms accept --urn resf:rockylinux-x86_64:9-base:latest"
      fi
      ;;
    openstack)
      # The provider reads OS_* from the environment, exactly like the CLI, so
      # a sourced RC file is the whole setup.
      [[ -n "${OS_AUTH_URL:-}" ]] || die "OS_AUTH_URL is unset. Source your OpenStack RC file first."
      [[ -n "${OS_PASSWORD:-}" ]] || die "OS_PASSWORD is unset. Source your RC file, or export it for this shell."
      openstack help share type create >/dev/null 2>&1 ||
        die "Manila CLI plugin missing. Install: pip install python-manilaclient"
      ok "OpenStack: ${OS_AUTH_URL} (project ${OS_PROJECT_NAME:-?})"
      ;;
  esac
done

mkdir -p "$BUILD_DIR/ssh" "$BUILD_DIR/ssh-openstack" "$REPO_ROOT/ansible/inventory"

# =============================================================================
# 2. Prepare deployment inputs
# =============================================================================
if ((DESTROY)); then
  step "Using existing state and generated user definitions"
  if [[ -n "$CSV_PATH" ]]; then
    destroy_users="$BUILD_DIR/destroy-users.auto.tfvars.json"
    python3 "$REPO_ROOT/lib/parse_users.py" "$CSV_PATH" --summary --out "$destroy_users" \
      || die "CSV validation failed; cannot prepare destroy inputs"
    for cloud in "${CLOUDS[@]}"; do
      saved_users="$REPO_ROOT/iac/$cloud/users.auto.tfvars.json"
      [[ -f "$saved_users" ]] ||
        die "missing saved deployment input $saved_users; refusing to synthesize destroy inputs from CSV"
      cmp -s "$destroy_users" "$saved_users" ||
        die "$CSV_PATH does not match the users used to deploy $cloud; use the original CSV"
    done
    rm -f "$destroy_users"
  fi
  for cloud in "${CLOUDS[@]}"; do
    [[ -f "$REPO_ROOT/iac/$cloud/users.auto.tfvars.json" ]] ||
      die "missing saved deployment input iac/$cloud/users.auto.tfvars.json; cannot destroy safely"
  done
  if [[ "$CLOUD" == "openstack" || "$CLOUD" == "both" ]]; then
    USERS_TFVARS="$REPO_ROOT/iac/openstack/users.auto.tfvars.json"
  fi
  ok "destroy inputs are present; the CSV is not required"
else
  step "Reading users from $(basename "$CSV_PATH")"

  USERS_TFVARS="$BUILD_DIR/users.auto.tfvars.json"
  python3 "$REPO_ROOT/lib/parse_users.py" "$CSV_PATH" --summary --out "$USERS_TFVARS" \
    || die "CSV validation failed. Fix the file and re-run; nothing was created."

  # Both stacks read the same generated file, so the two clouds can never drift
  # out of sync on who exists.
  for cloud in "${CLOUDS[@]}"; do
    cp "$USERS_TFVARS" "$REPO_ROOT/iac/$cloud/users.auto.tfvars.json"
  done
  ok "user definitions generated"
fi

# =============================================================================
# 3-N. Per cloud: terraform, inventory, ansible, verify
# =============================================================================
declare -A JUMP_HOSTS=()

for cloud in "${CLOUDS[@]}"; do
  if [[ "$cloud" == "openstack" ]]; then
    deploy_openstack
    [[ -n "${OPENSTACK_JUMP_HOST:-}" ]] &&
      JUMP_HOSTS[openstack]="$OPENSTACK_JUMP_HOST"
    continue
  fi

  STACK="$REPO_ROOT/iac/$cloud"
  TF=(terraform -chdir="$STACK")
  OUTPUT_JSON="$BUILD_DIR/$cloud-output.json"
  INVENTORY="$REPO_ROOT/ansible/inventory/$cloud.yml"

  # ---------------------------------------------------------------------------
  if ((DESTROY)); then
    step "Destroying the $cloud environment"
    [[ -f "$STACK/terraform.tfstate" ]] || { warn "no state for $cloud, nothing to destroy"; continue; }

    "${TF[@]}" init -input=false >/dev/null
    if ((AUTO_APPROVE)); then
      "${TF[@]}" destroy -auto-approve || die "$cloud destroy failed"
    else
      "${TF[@]}" destroy || die "$cloud destroy failed"
    fi
    rm -f "$INVENTORY" "$OUTPUT_JSON"
    ok "$cloud destroyed"
    continue
  fi

  # ---------------------------------------------------------------------------
  step "Terraform: $cloud infrastructure and identities"

  "${TF[@]}" init -input=false >/dev/null || die "$cloud terraform init failed"
  "${TF[@]}" validate || die "$cloud configuration is invalid"

  # A saved plan, so what gets applied is exactly what was reviewed. Applying
  # a plan file rather than re-planning is also what makes the demo video
  # reproducible.
  "${TF[@]}" plan -input=false -out="$STACK/tfplan" \
    || die "$cloud plan failed"
  chmod 600 "$STACK/tfplan"

  if ((PLAN_ONLY)); then
    ok "$cloud plan written to $STACK/tfplan (nothing applied)"
    continue
  fi

  if ((AUTO_APPROVE == 0)); then
    printf '\n'
    read -r -p "Apply the $cloud plan above? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted before any change was made"
  fi

  "${TF[@]}" apply -input=false "$STACK/tfplan" || die "$cloud apply failed"
  rm -f "$STACK/tfplan"
  "${TF[@]}" output -json > "$OUTPUT_JSON"
  chmod 600 "$OUTPUT_JSON"
  ok "$cloud infrastructure created"

  # ---------------------------------------------------------------------------
  step "Rendering the Ansible inventory for $cloud"
  python3 "$REPO_ROOT/lib/render_inventory.py" \
    --cloud "$cloud" \
    --terraform-output "$OUTPUT_JSON" \
    --out "$INVENTORY" || die "inventory generation failed for $cloud"

  jump_host="$(python3 -c "
import json,sys
data = json.load(open('$OUTPUT_JSON'))
print(data['inventory_data']['value']['jump_host'])
")"
  JUMP_HOSTS[$cloud]="$jump_host"
  ok "bastion at $jump_host"

  # ---------------------------------------------------------------------------
  step "Ansible: Moodle, storage mounts and the bastion for $cloud"

  if ((SKIP_ANSIBLE)); then
    warn "--skip-ansible: infrastructure exists but Moodle is not installed"
    hint "run it later: ansible-playbook -i $INVENTORY ansible/site.yml"
    continue
  fi

  # Cloud-init is still finishing when Terraform returns. Wait for the bastion
  # to accept SSH before Ansible starts, or the first play fails on a host that
  # would have been ready 20 seconds later.
  printf '     waiting for the bastion to accept SSH'
  ssh_key="$(python3 -c "
import json
print(json.load(open('$OUTPUT_JSON'))['inventory_data']['value']['ssh_key'])
")"
  admin_user="$(python3 -c "
import json
print(json.load(open('$OUTPUT_JSON'))['inventory_data']['value']['admin_username'])
")"
  known_hosts="$(dirname "$ssh_key")/known_hosts"
  readiness_check="cloud-init status --wait >/dev/null; rc=\$?;
    { test \$rc -eq 0 || test \$rc -eq 2; } || exit 42;
    test -f /var/lib/techsprint-nva-ready"
  bastion_ready=0
  for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="$known_hosts" -i "$ssh_key" \
           "${admin_user}@${jump_host}" "$readiness_check" 2>/dev/null; then
      printf ' up\n'
      bastion_ready=1
      break
    elif (( $? == 42 )); then
      die "$cloud bastion cloud-init failed; inspect /var/log/cloud-init-output.log"
    fi
    printf '.'
    sleep 5
  done
  ((bastion_ready == 1)) || die "$cloud bastion did not finish cloud-init within 5 minutes"

  ANSIBLE_CONFIG="$REPO_ROOT/ansible/ansible.cfg" \
    ansible-playbook -i "$INVENTORY" "$REPO_ROOT/ansible/site.yml" \
    || die "Ansible failed for $cloud. Re-run just that part with:
       ansible-playbook -i $INVENTORY ansible/site.yml"
  ok "$cloud application layer configured"

  # ---------------------------------------------------------------------------
  step "Verifying the $cloud deployment"
  "$REPO_ROOT/lib/verify.sh" --cloud "$cloud" --output "$OUTPUT_JSON" \
    || die "$cloud verification failed; see the table above and docs/troubleshooting.md"
done

# =============================================================================
# Summary
# =============================================================================
ELAPSED=$((SECONDS - START_TIME))

if ((DESTROY)); then
  printf '\n%s=== destroyed in %dm %ds ===%s\n\n' "$C_OK" $((ELAPSED / 60)) $((ELAPSED % 60)) "$C_RESET"
  exit 0
fi

if ((PLAN_ONLY)); then
  printf '\n%s=== planned in %dm %ds, nothing applied ===%s\n\n' \
    "$C_OK" $((ELAPSED / 60)) $((ELAPSED % 60)) "$C_RESET"
  exit 0
fi

printf '\n%s=== deployed in %dm %ds ===%s\n\n' "$C_OK" $((ELAPSED / 60)) $((ELAPSED % 60)) "$C_RESET"

for cloud in "${CLOUDS[@]}"; do
  printf '%s:\n' "$cloud"
  python3 - "$BUILD_DIR/$cloud-output.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
envs = data.get("environments", {}).get("value", {})
for slug, env in sorted(envs.items()):
    print(f"  {slug:<10} {len(env['moodle_instances'])} Moodle node(s), load balancer {env['load_balancer']}")
PY
  printf '  bastion: %s\n\n' "${JUMP_HOSTS[$cloud]:-unknown}"
done

cat <<EOF
Reach Moodle through the bastion (no Moodle instance has a public address):

  ssh -D 1080 -i <cloud-private-key> <admin-user>@<bastion-address>

  configure a SOCKS5 proxy at localhost:1080, then open the private
  load-balancer address shown above. This matches Moodle's canonical URL.

Azure helpers, when Azure was deployed:
  terraform -chdir=iac/azure output environments
  terraform -chdir=iac/azure output -raw ssh_config_snippet >> ~/.ssh/config

OpenStack helpers, when OpenStack was deployed:
  terraform -chdir=iac/openstack/data output environments
  terraform -chdir=iac/openstack/data output -raw ssh_config_snippet >> ~/.ssh/config

Its Terraform output is build/openstack-output.json and its generated inventory
is ansible/inventory/openstack.yml. Both are mode 0600.

Next: docs/testing-and-evidence.md for the checks the report needs.
EOF

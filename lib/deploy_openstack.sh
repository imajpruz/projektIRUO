#!/usr/bin/env bash
# Internal library sourced by deploy.sh. It is not a second entry point.
#
# Two roots, two applies:
#
#   iac/openstack        system-scoped identity: domain, projects, users,
#                        groups, role assignments, flavors, Octavia profile
#   iac/openstack/data   every tenant resource, with one provider alias per
#                        project, plus the management jump host
#
# The second root reads the first root's state directly and emits a single
# inventory_data output in the same shape as the Azure root. That removes the
# per-developer Terraform workspaces, the per-project token exchange, the typed
# stage files and the output merging that this library used to perform.
#
# Only the Manila share type is still driven from here: it is a cloud-wide
# object whose per-project access list is not exposed by the Terraform provider.

os_system_tf() {
  local stack="$1"
  shift
  env \
    -u OS_PROJECT_ID -u OS_PROJECT_NAME \
    -u OS_TENANT_ID -u OS_TENANT_NAME \
    -u OS_PROJECT_DOMAIN_ID -u OS_PROJECT_DOMAIN_NAME \
    OS_SYSTEM_SCOPE=all \
    terraform -chdir="$stack" "$@"
}

os_system_openstack() {
  env \
    -u OS_PROJECT_ID -u OS_PROJECT_NAME \
    -u OS_TENANT_ID -u OS_TENANT_NAME \
    -u OS_PROJECT_DOMAIN_ID -u OS_PROJECT_DOMAIN_NAME \
    OS_SYSTEM_SCOPE=all \
    openstack "$@"
}

# The data root sets tenant_name and project_domain_name on every provider, so
# the environment must not also carry a scope or the two disagree.
os_project_tf() {
  local stack="$1"
  shift
  env \
    -u OS_SYSTEM_SCOPE \
    -u OS_PROJECT_ID -u OS_PROJECT_NAME \
    -u OS_TENANT_ID -u OS_TENANT_NAME \
    -u OS_PROJECT_DOMAIN_ID -u OS_PROJECT_DOMAIN_NAME \
    terraform -chdir="$stack" "$@"
}

os_confirm_apply() {
  local label="$1"
  ((AUTO_APPROVE)) && return 0

  printf '\n'
  read -r -p "Apply the reviewed $label plan? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted before applying $label"
}

os_bootstrap_has_state() {
  [[ -s "$OS_BOOTSTRAP_STACK/terraform.tfstate" ]] &&
    os_system_tf "$OS_BOOTSTRAP_STACK" output -json 2>/dev/null |
    python3 -c 'import json,sys; raise SystemExit(0 if "bootstrap_public" in json.load(sys.stdin) else 1)'
}

os_read_bootstrap_output() {
  os_system_tf "$OS_BOOTSTRAP_STACK" output -json > "$OS_BOOTSTRAP_OUTPUT" \
    || die "could not read the OpenStack bootstrap output"
  chmod 600 "$OS_BOOTSTRAP_OUTPUT"
}

os_load_manila_share_type() {
  OS_MANILA_SHARE_TYPE="$(
    python3 - "$OS_BOOTSTRAP_OUTPUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["bootstrap_public"]["value"]
print(data["settings"]["manila_share_type"])
PY
  )"
  [[ -n "$OS_MANILA_SHARE_TYPE" ]] || die "Manila share type is missing from bootstrap output"
}

os_ensure_manila_share_type() {
  if ! os_system_openstack share type show "$OS_MANILA_SHARE_TYPE" >/dev/null 2>&1; then
    os_system_openstack share type create \
      "$OS_MANILA_SHARE_TYPE" false --public false \
      --extra-specs share_backend_name=cephfs >/dev/null \
      || die "failed to create Manila share type $OS_MANILA_SHARE_TYPE"
  fi

  os_system_openstack share type set \
    "$OS_MANILA_SHARE_TYPE" --extra-specs share_backend_name=cephfs >/dev/null \
    || die "failed to select the CephFS backend on $OS_MANILA_SHARE_TYPE"

  while IFS= read -r project_id; do
    [[ -n "$project_id" ]] || continue
    if ! os_system_openstack share type access list "$OS_MANILA_SHARE_TYPE" 2>/dev/null |
      awk -v id="$project_id" 'index($0,id){found=1} END{exit !found}'; then
      os_system_openstack share type access create \
        "$OS_MANILA_SHARE_TYPE" "$project_id" >/dev/null \
        || die "failed to grant Manila type access to project $project_id"
    fi
  done < <(python3 - "$OS_BOOTSTRAP_OUTPUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["bootstrap_public"]["value"]
for project in data["developer_projects"].values():
    print(project["id"])
PY
)
}

os_delete_manila_share_type() {
  if os_system_openstack share type show "$OS_MANILA_SHARE_TYPE" >/dev/null 2>&1; then
    os_system_openstack share type delete "$OS_MANILA_SHARE_TYPE" >/dev/null \
      || die "failed to delete Manila share type $OS_MANILA_SHARE_TYPE"
  fi
}

os_wait_for_jump() {
  local jump_host="$1" ssh_key="$2" admin_user="$3" known_hosts
  known_hosts="$(dirname "$ssh_key")/known_hosts"

  printf '     waiting for the bastion to accept SSH'
  for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$known_hosts" \
      -i "$ssh_key" "${admin_user}@${jump_host}" \
      "cloud-init status --wait >/dev/null; rc=\$?;
            { test \$rc -eq 0 || test \$rc -eq 2; } || exit 42;
            systemctl is-active --quiet techsprint-jump-routes.service" 2>/dev/null; then
      printf ' up\n'
      return 0
    elif (($? == 42)); then
      printf ' cloud-init failed\n'
      return 42
    fi
    printf '.'
    sleep 5
  done
  printf ' timeout\n'
  return 1
}

os_inventory_value() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['inventory_data']['value'][sys.argv[2]])" \
    "$OS_OUTPUT" "$1"
}

deploy_openstack() {
  OS_BOOTSTRAP_STACK="$REPO_ROOT/iac/openstack"
  OS_DATA_STACK="$OS_BOOTSTRAP_STACK/data"
  OS_LAB_TFVARS="$OS_BOOTSTRAP_STACK/terraform.tfvars"
  OS_BOOTSTRAP_OUTPUT="$BUILD_DIR/openstack-bootstrap-output.json"
  OS_OUTPUT="$BUILD_DIR/openstack-output.json"
  OS_INVENTORY="$REPO_ROOT/ansible/inventory/openstack.yml"
  OS_MANILA_SHARE_TYPE=""

  [[ -f "$OS_LAB_TFVARS" ]] ||
    die "OpenStack lab configuration missing: copy iac/openstack/terraform.tfvars.example to terraform.tfvars"

  # The data root declares the same developers/leads variables, so it reads the
  # same generated file. On destroy the file already exists from the deployment.
  if [[ -f "$OS_BOOTSTRAP_STACK/users.auto.tfvars.json" ]]; then
    cp "$OS_BOOTSTRAP_STACK/users.auto.tfvars.json" "$OS_DATA_STACK/users.auto.tfvars.json"
  fi

  # Written into the guest rclone configuration, so it always matches the cloud
  # Terraform itself authenticated to.
  export TF_VAR_object_auth_url="$OS_AUTH_URL"

  os_system_tf "$OS_BOOTSTRAP_STACK" init -input=false >/dev/null \
    || die "OpenStack bootstrap terraform init failed"
  os_project_tf "$OS_DATA_STACK" init -input=false >/dev/null \
    || die "OpenStack data terraform init failed"

  # ---------------------------------------------------------------------------
  if ((DESTROY)); then
    step "Destroying the OpenStack environment"

    [[ -s "$OS_BOOTSTRAP_STACK/terraform.tfstate" ]] || {
      warn "no OpenStack bootstrap state, nothing to destroy"
      return 0
    }
    [[ -f "$OS_DATA_STACK/users.auto.tfvars.json" ]] ||
      die "missing iac/openstack/data/users.auto.tfvars.json; cannot destroy safely"

    os_read_bootstrap_output
    os_load_manila_share_type

    # The data root must go first: it reads the bootstrap state, and its
    # resources live inside the projects the bootstrap root owns.
    if [[ -s "$OS_DATA_STACK/terraform.tfstate" ]]; then
      if ((AUTO_APPROVE)); then
        os_project_tf "$OS_DATA_STACK" destroy -auto-approve || die "OpenStack data destroy failed"
      else
        os_project_tf "$OS_DATA_STACK" destroy || die "OpenStack data destroy failed"
      fi
    fi

    os_delete_manila_share_type

    if ((AUTO_APPROVE)); then
      os_system_tf "$OS_BOOTSTRAP_STACK" destroy -auto-approve \
        || die "OpenStack bootstrap destroy failed"
    else
      os_system_tf "$OS_BOOTSTRAP_STACK" destroy \
        || die "OpenStack bootstrap destroy failed"
    fi

    rm -f "$OS_BOOTSTRAP_OUTPUT" "$OS_OUTPUT" "$OS_INVENTORY"
    ok "OpenStack environment destroyed"
    return 0
  fi

  # ---------------------------------------------------------------------------
  step "Terraform: OpenStack identity and global bootstrap"

  os_system_tf "$OS_BOOTSTRAP_STACK" validate \
    || die "OpenStack bootstrap configuration is invalid"
  os_system_tf "$OS_BOOTSTRAP_STACK" plan -input=false \
    -out="$BUILD_DIR/openstack-bootstrap.tfplan" \
    || die "OpenStack bootstrap plan failed"
  chmod 600 "$BUILD_DIR/openstack-bootstrap.tfplan"

  if ((PLAN_ONLY)); then
    step "Terraform: OpenStack data plane"
    if os_bootstrap_has_state; then
      os_project_tf "$OS_DATA_STACK" validate \
        || die "OpenStack data configuration is invalid"
      os_project_tf "$OS_DATA_STACK" plan -input=false \
        -out="$BUILD_DIR/openstack-data.tfplan" \
        || die "OpenStack data plan failed"
      chmod 600 "$BUILD_DIR/openstack-data.tfplan"
      ok "both OpenStack plans written to build/ (nothing applied)"
    else
      # Provider aliases authenticate to projects the bootstrap root creates,
      # so there is nothing to plan against on a fresh deployment.
      warn "the data-plane plan needs the bootstrap projects to exist first"
      hint "apply the bootstrap, then re-run --plan-only to see the data plan"
    fi
    return 0
  fi

  os_confirm_apply "OpenStack bootstrap"
  os_system_tf "$OS_BOOTSTRAP_STACK" apply -input=false \
    "$BUILD_DIR/openstack-bootstrap.tfplan" \
    || die "OpenStack bootstrap apply failed"
  rm -f "$BUILD_DIR/openstack-bootstrap.tfplan"

  os_read_bootstrap_output
  os_load_manila_share_type
  os_ensure_manila_share_type
  ok "OpenStack identities, projects, flavors, and Manila type created"

  # ---------------------------------------------------------------------------
  step "Terraform: OpenStack networks, instances, storage and jump host"

  os_project_tf "$OS_DATA_STACK" validate \
    || die "OpenStack data configuration is invalid"
  os_project_tf "$OS_DATA_STACK" plan -input=false \
    -out="$BUILD_DIR/openstack-data.tfplan" \
    || die "OpenStack data plan failed"
  chmod 600 "$BUILD_DIR/openstack-data.tfplan"

  os_confirm_apply "OpenStack data plane"
  os_project_tf "$OS_DATA_STACK" apply -input=false \
    "$BUILD_DIR/openstack-data.tfplan" \
    || die "OpenStack data apply failed"
  rm -f "$BUILD_DIR/openstack-data.tfplan"

  os_project_tf "$OS_DATA_STACK" output -json > "$OS_OUTPUT" \
    || die "could not read the OpenStack data output"
  chmod 600 "$OS_OUTPUT"
  ok "OpenStack developer environments and the single floating IP created"

  # ---------------------------------------------------------------------------
  step "Rendering the Ansible inventory for OpenStack"
  python3 "$REPO_ROOT/lib/render_inventory.py" \
    --cloud openstack \
    --terraform-output "$OS_OUTPUT" \
    --out "$OS_INVENTORY" \
    || die "inventory generation failed for OpenStack"

  OPENSTACK_JUMP_HOST="$(os_inventory_value jump_host)"
  local ssh_key admin_user
  ssh_key="$(os_inventory_value ssh_key)"
  admin_user="$(os_inventory_value admin_username)"
  ok "bastion at $OPENSTACK_JUMP_HOST"

  # ---------------------------------------------------------------------------
  step "Ansible: OpenStack Moodle, mounts, load balancers, and jump host"
  if ((SKIP_ANSIBLE)); then
    warn "--skip-ansible: infrastructure exists but Moodle is not installed"
    hint "run it later: ansible-playbook -i $OS_INVENTORY ansible/site.yml"
    return 0
  fi

  os_wait_for_jump "$OPENSTACK_JUMP_HOST" "$ssh_key" "$admin_user" \
    || die "OpenStack jump host did not become reachable"
  ANSIBLE_CONFIG="$REPO_ROOT/ansible/ansible.cfg" \
    ansible-playbook -i "$OS_INVENTORY" "$REPO_ROOT/ansible/site.yml" \
    || die "Ansible failed for OpenStack. Re-run just that part with:
       ansible-playbook -i $OS_INVENTORY ansible/site.yml"
  ok "OpenStack application layer configured"

  # ---------------------------------------------------------------------------
  step "Verifying the OpenStack deployment"
  "$REPO_ROOT/lib/verify.sh" --cloud openstack --output "$OS_OUTPUT" \
    || die "OpenStack verification failed; see the table above and docs/troubleshooting.md"
  ok "OpenStack verification passed"
}

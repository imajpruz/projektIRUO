#!/usr/bin/env bash
# Internal library sourced by deploy.sh. It is not a second entry point.

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
      python3 -c 'import json,sys; raise SystemExit(0 if "bootstrap_data" in json.load(sys.stdin) else 1)'
}

os_load_manila_share_type() {
  OS_MANILA_SHARE_TYPE="$(
    python3 - "$OS_BOOTSTRAP_OUTPUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["bootstrap_data"]["value"]
print(data["settings"]["manila_share_type"])
PY
  )"
  [[ -n "$OS_MANILA_SHARE_TYPE" ]] || die "Manila share type is missing from bootstrap output"
}

os_developer_slugs() {
  python3 - "$USERS_TFVARS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(sorted(data["developers"])))
PY
}

os_assert_no_stale_workspaces() {
  local workspace
  while IFS= read -r workspace; do
    [[ -n "$workspace" ]] || continue
    if ! python3 - "$USERS_TFVARS" "$workspace" <<'PY'
import json, sys
developers = json.load(open(sys.argv[1], encoding="utf-8"))["developers"]
raise SystemExit(0 if sys.argv[2] in developers else 1)
PY
    then
      die "OpenStack workspace '$workspace' is absent from the CSV. Destroy it with the original CSV before continuing."
    fi
  done < <(
    os_project_tf "$OS_ENVIRONMENT_STACK" workspace list |
      awk '{gsub(/^[* ]+|[ ]+$/, ""); if ($0 != "" && $0 != "default") print}'
  )
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
data = json.load(open(sys.argv[1], encoding="utf-8"))["bootstrap_data"]["value"]
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

os_generate_environment_vars() {
  local slug="$1" output="$2"
  python3 "$REPO_ROOT/lib/openstack_stages.py" environment-vars \
    --bootstrap-output "$OS_BOOTSTRAP_OUTPUT" \
    --slug "$slug" \
    --auth-url "$OS_AUTH_URL" \
    --out "$output"
}

os_collect_environment_output() {
  local slug="$1"
  local output="$OS_ENV_OUTPUT_DIR/$slug.json"
  os_project_tf "$OS_ENVIRONMENT_STACK" workspace select "$slug" >/dev/null
  os_project_tf "$OS_ENVIRONMENT_STACK" output -json > "$output"
  chmod 600 "$output"
}

os_generate_management_vars() {
  python3 "$REPO_ROOT/lib/openstack_stages.py" management-vars \
    --bootstrap-output "$OS_BOOTSTRAP_OUTPUT" \
    --environment-output-dir "$OS_ENV_OUTPUT_DIR" \
    --out "$OS_MANAGEMENT_VARS"
}

os_init_stacks() {
  os_system_tf "$OS_BOOTSTRAP_STACK" init -input=false >/dev/null \
    || die "OpenStack bootstrap terraform init failed"
  os_project_tf "$OS_ENVIRONMENT_STACK" init -input=false >/dev/null \
    || die "OpenStack environment terraform init failed"
  os_project_tf "$OS_MANAGEMENT_STACK" init -input=false >/dev/null \
    || die "OpenStack management terraform init failed"
}

os_plan_bootstrap() {
  os_system_tf "$OS_BOOTSTRAP_STACK" validate \
    || die "OpenStack bootstrap configuration is invalid"
  os_system_tf "$OS_BOOTSTRAP_STACK" plan -input=false \
    -out="$BUILD_DIR/openstack-bootstrap.tfplan" \
    || die "OpenStack bootstrap plan failed"
  chmod 600 "$BUILD_DIR/openstack-bootstrap.tfplan"
}

os_plan_environments() {
  local apply_plans="$1" slug stage_vars plan_file

  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    stage_vars="$OS_STAGE_VARS_DIR/$slug.json"
    plan_file="$BUILD_DIR/openstack-$slug.tfplan"

    if ! os_project_tf "$OS_ENVIRONMENT_STACK" workspace select "$slug" >/dev/null 2>&1; then
      if ((apply_plans)); then
        os_project_tf "$OS_ENVIRONMENT_STACK" workspace new "$slug" >/dev/null \
          || die "failed to create Terraform workspace $slug"
      else
        warn "OpenStack $slug plan deferred until its bootstrap project is applied"
        continue
      fi
    fi

    os_generate_environment_vars "$slug" "$stage_vars"
    os_project_tf "$OS_ENVIRONMENT_STACK" validate \
      || die "OpenStack environment configuration is invalid"
    os_project_tf "$OS_ENVIRONMENT_STACK" plan -input=false \
      -var-file="$stage_vars" \
      -out="$plan_file" \
      || die "OpenStack plan failed for $slug"
    chmod 600 "$plan_file"

    if ((apply_plans)); then
      os_confirm_apply "OpenStack $slug environment"
      os_project_tf "$OS_ENVIRONMENT_STACK" apply -input=false "$plan_file" \
        || die "OpenStack apply failed for $slug"
      rm -f "$plan_file"
      os_collect_environment_output "$slug"
    elif os_project_tf "$OS_ENVIRONMENT_STACK" output -json 2>/dev/null |
      python3 -c 'import json,sys; raise SystemExit(0 if "management_attachment" in json.load(sys.stdin) else 1)'; then
      os_collect_environment_output "$slug"
    fi
  done < <(os_developer_slugs)
}

os_plan_management() {
  local apply_plan="$1"

  os_generate_management_vars
  os_project_tf "$OS_MANAGEMENT_STACK" validate \
    || die "OpenStack management configuration is invalid"
  os_project_tf "$OS_MANAGEMENT_STACK" plan -input=false \
    -var-file="$OS_MANAGEMENT_VARS" \
    -out="$BUILD_DIR/openstack-management.tfplan" \
    || die "OpenStack management plan failed"
  chmod 600 "$BUILD_DIR/openstack-management.tfplan"

  if ((apply_plan)); then
    os_confirm_apply "OpenStack management"
    os_project_tf "$OS_MANAGEMENT_STACK" apply -input=false \
      "$BUILD_DIR/openstack-management.tfplan" \
      || die "OpenStack management apply failed"
    rm -f "$BUILD_DIR/openstack-management.tfplan"
    os_project_tf "$OS_MANAGEMENT_STACK" output -json > "$OS_MANAGEMENT_OUTPUT"
    chmod 600 "$OS_MANAGEMENT_OUTPUT"
  fi
}

os_merge_outputs() {
  python3 "$REPO_ROOT/lib/openstack_stages.py" merge \
    --bootstrap-output "$OS_BOOTSTRAP_OUTPUT" \
    --management-output "$OS_MANAGEMENT_OUTPUT" \
    --environment-output-dir "$OS_ENV_OUTPUT_DIR" \
    --out "$OS_COMBINED_OUTPUT"
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
    elif (( $? == 42 )); then
      printf ' cloud-init failed\n'
      return 42
    fi
    printf '.'
    sleep 5
  done
  printf ' timeout\n'
  return 1
}

os_destroy_staged() {
  local slug stage_vars

  [[ -s "$OS_BOOTSTRAP_STACK/terraform.tfstate" ]] || {
    warn "no OpenStack bootstrap state, nothing to destroy"
    return 0
  }

  os_system_tf "$OS_BOOTSTRAP_STACK" output -json > "$OS_BOOTSTRAP_OUTPUT"
  chmod 600 "$OS_BOOTSTRAP_OUTPUT"
  os_load_manila_share_type
  mkdir -p "$OS_ENV_OUTPUT_DIR" "$OS_STAGE_VARS_DIR"

  mapfile -t workspaces < <(
    os_project_tf "$OS_ENVIRONMENT_STACK" workspace list |
      awk '{gsub(/^[* ]+|[ ]+$/, ""); if ($0 != "" && $0 != "default") print}'
  )

  for slug in "${workspaces[@]}"; do
    os_generate_environment_vars "$slug" "$OS_STAGE_VARS_DIR/$slug.json"
    if [[ ! -f "$OS_MANAGEMENT_VARS" ]]; then
      os_collect_environment_output "$slug"
    fi
  done

  if [[ -s "$OS_MANAGEMENT_STACK/terraform.tfstate" ]]; then
    if [[ ! -f "$OS_MANAGEMENT_VARS" ]]; then
      compgen -G "$OS_ENV_OUTPUT_DIR/*.json" >/dev/null ||
        die "saved management destroy inputs are missing and no environment outputs can reconstruct them"
      os_generate_management_vars
    fi
    if ((AUTO_APPROVE)); then
      os_project_tf "$OS_MANAGEMENT_STACK" destroy -auto-approve \
        -var-file="$OS_MANAGEMENT_VARS" \
        || die "OpenStack management destroy failed"
    else
      os_project_tf "$OS_MANAGEMENT_STACK" destroy \
        -var-file="$OS_MANAGEMENT_VARS" \
        || die "OpenStack management destroy failed"
    fi
  fi

  for slug in "${workspaces[@]}"; do
    stage_vars="$OS_STAGE_VARS_DIR/$slug.json"
    os_project_tf "$OS_ENVIRONMENT_STACK" workspace select "$slug" >/dev/null
    if ((AUTO_APPROVE)); then
      os_project_tf "$OS_ENVIRONMENT_STACK" destroy -auto-approve \
        -var-file="$stage_vars" \
        || die "OpenStack destroy failed for $slug"
    else
      os_project_tf "$OS_ENVIRONMENT_STACK" destroy \
        -var-file="$stage_vars" \
        || die "OpenStack destroy failed for $slug"
    fi
  done

  os_delete_manila_share_type

  if ((AUTO_APPROVE)); then
    os_system_tf "$OS_BOOTSTRAP_STACK" destroy -auto-approve \
      || die "OpenStack bootstrap destroy failed"
  else
    os_system_tf "$OS_BOOTSTRAP_STACK" destroy \
      || die "OpenStack bootstrap destroy failed"
  fi

  os_project_tf "$OS_ENVIRONMENT_STACK" workspace select default >/dev/null
  for slug in "${workspaces[@]}"; do
    os_project_tf "$OS_ENVIRONMENT_STACK" workspace delete "$slug" >/dev/null \
      || warn "empty workspace $slug could not be removed"
  done
}

deploy_openstack() {
  OS_BOOTSTRAP_STACK="$REPO_ROOT/iac/openstack"
  OS_ENVIRONMENT_STACK="$OS_BOOTSTRAP_STACK/environment"
  OS_MANAGEMENT_STACK="$OS_BOOTSTRAP_STACK/management"
  OS_LAB_TFVARS="$OS_BOOTSTRAP_STACK/terraform.tfvars"
  OS_BOOTSTRAP_OUTPUT="$BUILD_DIR/openstack-bootstrap-output.json"
  OS_MANAGEMENT_OUTPUT="$BUILD_DIR/openstack-management-output.json"
  OS_COMBINED_OUTPUT="$BUILD_DIR/openstack-output.json"
  OS_ENV_OUTPUT_DIR="$BUILD_DIR/openstack-environments"
  OS_STAGE_VARS_DIR="$BUILD_DIR/openstack-stage-vars"
  OS_MANAGEMENT_VARS="$OS_MANAGEMENT_STACK/deployment.auto.tfvars.json"
  OS_MANILA_SHARE_TYPE=""

  [[ -f "$OS_LAB_TFVARS" ]] ||
    die "OpenStack lab configuration missing: copy iac/openstack/terraform.tfvars.example to terraform.tfvars"

  mkdir -p "$OS_ENV_OUTPUT_DIR" "$OS_STAGE_VARS_DIR"
  os_init_stacks

  if ((DESTROY)); then
    step "Destroying the staged OpenStack environment"
    os_destroy_staged
    rm -rf "$OS_ENV_OUTPUT_DIR" "$OS_STAGE_VARS_DIR"
    rm -f "$OS_BOOTSTRAP_OUTPUT" "$OS_MANAGEMENT_OUTPUT" "$OS_COMBINED_OUTPUT" \
      "$OS_MANAGEMENT_VARS" "$REPO_ROOT/ansible/inventory/openstack.yml"
    ok "OpenStack environment destroyed"
    return 0
  fi

  rm -f "$OS_ENV_OUTPUT_DIR"/*.json "$OS_STAGE_VARS_DIR"/*.json
  os_assert_no_stale_workspaces

  step "Terraform: OpenStack identity and global bootstrap"
  os_plan_bootstrap

  if ((PLAN_ONLY)); then
    if os_bootstrap_has_state; then
      os_system_tf "$OS_BOOTSTRAP_STACK" output -json > "$OS_BOOTSTRAP_OUTPUT"
      chmod 600 "$OS_BOOTSTRAP_OUTPUT"

      step "Terraform: existing OpenStack developer project plans"
      os_plan_environments 0

      step "Terraform: existing OpenStack management plan"
      if compgen -G "$OS_ENV_OUTPUT_DIR/*.json" >/dev/null; then
        os_plan_management 0
      else
        warn "management plan requires applied developer-network outputs"
      fi
    else
      step "Terraform: developer plans deferred until bootstrap exists"
      warn "a fresh staged deployment cannot plan project-scoped resources before project IDs exist"
      step "Terraform: management plan deferred until developer networks exist"
      warn "nothing was applied"
    fi
    return 0
  fi

  os_confirm_apply "OpenStack bootstrap"
  os_system_tf "$OS_BOOTSTRAP_STACK" apply -input=false \
    "$BUILD_DIR/openstack-bootstrap.tfplan" \
    || die "OpenStack bootstrap apply failed"
  rm -f "$BUILD_DIR/openstack-bootstrap.tfplan"
  os_system_tf "$OS_BOOTSTRAP_STACK" output -json > "$OS_BOOTSTRAP_OUTPUT"
  chmod 600 "$OS_BOOTSTRAP_OUTPUT"
  os_load_manila_share_type
  os_ensure_manila_share_type
  ok "OpenStack identities, projects, flavors, and Manila type created"

  step "Terraform: project-scoped OpenStack developer environments"
  os_plan_environments 1
  ok "OpenStack developer environments created in their owning projects"

  step "Terraform: central multihomed OpenStack jump host"
  os_plan_management 1
  ok "OpenStack management project and single floating IP created"

  step "Rendering the Ansible inventory for OpenStack"
  os_merge_outputs
  python3 "$REPO_ROOT/lib/render_inventory.py" \
    --cloud openstack \
    --terraform-output "$OS_COMBINED_OUTPUT" \
    --out "$REPO_ROOT/ansible/inventory/openstack.yml" \
    || die "inventory generation failed for OpenStack"

  OPENSTACK_JUMP_HOST="$(
    python3 -c "import json; print(json.load(open('$OS_COMBINED_OUTPUT'))['inventory_data']['value']['jump_host'])"
  )"
  ssh_key="$(
    python3 -c "import json; print(json.load(open('$OS_COMBINED_OUTPUT'))['inventory_data']['value']['ssh_key'])"
  )"
  admin_user="$(
    python3 -c "import json; print(json.load(open('$OS_COMBINED_OUTPUT'))['inventory_data']['value']['admin_username'])"
  )"
  ok "OpenStack inventory rendered"

  step "Ansible: OpenStack Moodle, mounts, load balancers, and jump host"
  if ((SKIP_ANSIBLE)); then
    warn "--skip-ansible: infrastructure exists but Moodle is not installed"
  else
    os_wait_for_jump "$OPENSTACK_JUMP_HOST" "$ssh_key" "$admin_user" \
      || die "OpenStack jump host did not become reachable"
    ANSIBLE_CONFIG="$REPO_ROOT/ansible/ansible.cfg" \
      ansible-playbook -i "$REPO_ROOT/ansible/inventory/openstack.yml" \
      "$REPO_ROOT/ansible/site.yml" \
      || die "Ansible failed for OpenStack"
    ok "OpenStack application layer configured"
  fi

  step "Verifying the OpenStack deployment"
  if ((SKIP_ANSIBLE)); then
    warn "verification skipped because --skip-ansible was used"
  else
    "$REPO_ROOT/lib/verify.sh" --cloud openstack --output "$OS_COMBINED_OUTPUT" \
      || die "OpenStack verification failed"
    ok "OpenStack verification passed"
  fi
}

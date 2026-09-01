#!/usr/bin/env bash
# Rubric-focused smoke tests for a deployed Azure or OpenStack environment.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'
  C_HEAD=$'\033[1;36m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_OK=""; C_ERR=""; C_HEAD=""; C_DIM=""
fi

CLOUD=""
OUTPUT_JSON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud) CLOUD="${2:-}"; shift 2 ;;
    --output) OUTPUT_JSON="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$CLOUD" == "azure" || "$CLOUD" == "openstack" ]] ||
  { echo "--cloud must be azure or openstack" >&2; exit 2; }
OUTPUT_JSON="${OUTPUT_JSON:-$REPO_ROOT/build/$CLOUD-output.json}"
[[ -f "$OUTPUT_JSON" ]] ||
  { echo "terraform output not found: $OUTPUT_JSON" >&2; exit 2; }

read_json() {
  python3 -c "
import json
data = json.load(open('$OUTPUT_JSON'))
inv = data['inventory_data']['value']
$1
"
}

JUMP="$(read_json "print(inv['jump_host'])")"
SSH_KEY="$(read_json "print(inv['ssh_key'])")"
ADMIN="$(read_json "print(inv['admin_username'])")"
ENV_SLUGS="$(read_json "print(' '.join(sorted(inv['environments'])))")"

KNOWN_HOSTS="$(dirname "$SSH_KEY")/known_hosts"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -i "$SSH_KEY")
PROXY=(-o "ProxyCommand=ssh -W %h:%p -q ${SSH_OPTS[*]} ${ADMIN}@${JUMP}")

PASS=0
FAIL=0
declare -a ROWS=()

record() {
  local result="$1" rubric="$2" label="$3"
  ROWS+=("$result|$rubric|$label")
  if [[ "$result" == "PASS" ]]; then
    printf '%s  ok%s  %-6s %s\n' "$C_OK" "$C_RESET" "$rubric" "$label"
    PASS=$((PASS + 1))
  else
    printf '%sfail%s  %-6s %s\n' "$C_ERR" "$C_RESET" "$rubric" "$label"
    FAIL=$((FAIL + 1))
  fi
}

check() {
  local rubric="$1" label="$2"
  shift 2
  if "$@" >/tmp/techsprint-check.out 2>&1; then
    record PASS "$rubric" "$label"
  else
    record FAIL "$rubric" "$label"
    awk 'NR <= 3 { print "        " $0 }' /tmp/techsprint-check.out
  fi
}

check_blocked() {
  local rubric="$1" label="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    record FAIL "$rubric" "$label (unexpectedly reachable)"
  else
    record PASS "$rubric" "$label"
  fi
}

on_node() {
  local ip="$1"
  shift
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "${PROXY[@]}" "${ADMIN}@${ip}" "$@"
}

openstack_as_identity() {
  local username="$1" password="$2" project="$3" domain="$4"
  shift 4
  (
    unset OS_SYSTEM_SCOPE OS_PROJECT_ID OS_TENANT_ID OS_TENANT_NAME
    export OS_USERNAME="$username" OS_PASSWORD="$password"
    export OS_USER_DOMAIN_NAME="$domain"
    export OS_PROJECT_NAME="$project" OS_PROJECT_DOMAIN_NAME="$domain"
    openstack "$@"
  )
}

printf '\n%s== Access and application ==%s\n' "$C_HEAD" "$C_RESET"
check "I2/I4" "bastion reachable on SSH" \
  ssh "${SSH_OPTS[@]}" "${ADMIN}@${JUMP}" true

for slug in $ENV_SLUGS; do
  printf '\n%s-- %s --%s\n' "$C_DIM" "$slug" "$C_RESET"
  mapfile -t IPS < <(
    read_json "print('\n'.join(inv['environments']['$slug']['moodle_ips']))"
  )
  LB="$(read_json "print(inv['environments']['$slug']['load_balancer'])")"

  check "I2/I4" "$slug: two Moodle instances exist" test "${#IPS[@]}" -eq 2
  if [[ "$CLOUD" == "azure" ]]; then
    BLOB_ACCOUNT="$(read_json "print(inv['environments']['$slug']['blob_storage_account'])")"
    FILE_ACCOUNT="$(read_json "print(inv['environments']['$slug']['file_storage_account'])")"
    check "I4" "$slug: Blob and Files use separate accounts" \
      test "$BLOB_ACCOUNT" != "$FILE_ACCOUNT"
  fi

  for index in "${!IPS[@]}"; do
    ip="${IPS[$index]}"
    node=$((index + 1))

    check "I2/I4" "$slug node $node: reachable through bastion" on_node "$ip" true
    check "I3/I5" "$slug node $node: 2 vCPU" \
      on_node "$ip" "test \$(nproc) -eq 2"
    check "I3/I5" "$slug node $node: at least 3.5 GB RAM" \
      on_node "$ip" "test \$(awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo) -ge 3500"
    check "I2/I4" "$slug node $node: approved Linux image" \
      on_node "$ip" ". /etc/os-release; case \"\$ID\" in rocky|rhel|centos) exit 0;; *) exit 1;; esac"
    check "I2/I4" "$slug node $node: data disk mounted" \
      on_node "$ip" "findmnt --mountpoint /mnt/techsprint-data"
    check "I2/I4" "$slug node $node: file storage mounted and writable" \
      on_node "$ip" "findmnt --mountpoint /srv/moodle-backups &&
        sudo -u apache sh -c 'set -e; p=/srv/moodle-backups/.verify-\$\$;
          trap \"rm -f -- \\\"\$p\\\"\" EXIT; printf ok >\"\$p\"; grep -qx ok \"\$p\"'"
    check "I2/I4" "$slug node $node: object storage mounted and writable" \
      on_node "$ip" "findmnt --mountpoint /var/moodledata &&
        sudo -u apache sh -c 'set -e; p=/var/moodledata/.verify-\$\$;
          trap \"rm -f -- \\\"\$p\\\"\" EXIT; printf ok >\"\$p\"; grep -qx ok \"\$p\"'"
    check "I2/I4" "$slug node $node: outbound Internet works" \
      on_node "$ip" "curl -fsSI --max-time 15 https://packaging.moodle.org/ >/dev/null"
    check "I2/I4" "$slug node $node: Moodle health endpoint works" \
      on_node "$ip" "curl -fsS --max-time 8 http://127.0.0.1/healthz.php | grep -qx 'status=ok'"

    if [[ "$CLOUD" == "azure" ]]; then
      check "I4" "$slug node $node: managed identity and root-only SMB key" \
        on_node "$ip" "grep -q 'mode: msi' /etc/blobfuse2-techsprint.yaml &&
          grep -Fq 'account-name: $BLOB_ACCOUNT' /etc/blobfuse2-techsprint.yaml &&
          grep -Fqx 'username=$FILE_ACCOUNT' /etc/smbcredentials-techsprint &&
          test \$(stat -c %a /etc/smbcredentials-techsprint) -eq 600"
    else
      OBJECT_USER="$(read_json "print(inv['environments']['$slug']['object_username'])")"
      PROJECT_NAME="$(read_json "print(inv['environments']['$slug']['project_name'])")"
      check "I2" "$slug node $node: project-scoped Swift credential" \
        on_node "$ip" "test \$(stat -c %a /etc/rclone-techsprint.conf) -eq 600 &&
          test \"\$(stat -c %U /etc/rclone-techsprint.conf)\" = apache &&
          grep -Fqx 'user = $OBJECT_USER' /etc/rclone-techsprint.conf &&
          grep -q '^user = svc-techsprint-' /etc/rclone-techsprint.conf &&
          grep -Fqx 'tenant = $PROJECT_NAME' /etc/rclone-techsprint.conf"
    fi
  done

  check "I2/I4" "$slug: load balancer serves Moodle" \
    ssh "${SSH_OPTS[@]}" "${ADMIN}@${JUMP}" \
      "curl -fsSL --max-time 15 http://${LB}/ | grep -qi moodle"
done

read -r -a SLUG_ARRAY <<< "$ENV_SLUGS"

printf '\n%s== Identity scope ==%s\n' "$C_HEAD" "$C_RESET"
if [[ "$CLOUD" == "azure" ]]; then
  for slug in $ENV_SLUGS; do
    CLIENT_ID="$(read_json "print(data['identity_summary']['value']['developers']['$slug']['client_id'])")"
    RG="$(read_json "print(inv['environments']['$slug']['resource_group'])")"
    total_assignment_count="$(az role assignment list --assignee "$CLIENT_ID" --all \
      --query "length(@)" -o tsv 2>/dev/null || echo -1)"
    own_assignment_count="$(az role assignment list --assignee "$CLIENT_ID" --all \
      --query "length([?ends_with(scope, '/resourceGroups/$RG')])" -o tsv 2>/dev/null || echo -1)"
    check "I5" "$slug identity is scoped to its own resource group" \
      test "$own_assignment_count" -eq 1
    check "I5" "$slug identity has no additional assignments" \
      test "$total_assignment_count" -eq 1
  done
  LEAD_SLUG="$(read_json "print(sorted(data['identity_summary']['value']['leads'])[0])")"
  CLIENT_ID="$(read_json "print(data['identity_summary']['value']['leads']['$LEAD_SLUG']['client_id'])")"
  total_assignment_count="$(az role assignment list --assignee "$CLIENT_ID" --all \
    --query "length(@)" -o tsv 2>/dev/null || echo -1)"
  mapfile -t EXPECTED_RGS < <(read_json "
print(inv['hub_resource_group'])
for env in inv['environments'].values():
    print(env['resource_group'])
")
  lead_scopes_valid=1
  for RG in "${EXPECTED_RGS[@]}"; do
    assignment_count="$(az role assignment list --assignee "$CLIENT_ID" --all \
      --query "length([?ends_with(scope, '/resourceGroups/$RG')])" -o tsv 2>/dev/null || echo -1)"
    ((assignment_count == 1)) || lead_scopes_valid=0
  done
  check "I5" "$LEAD_SLUG is scoped to every TechSprint resource group" \
    test "$lead_scopes_valid" -eq 1
  check "I5" "$LEAD_SLUG has no assignments outside TechSprint" \
    test "$total_assignment_count" -eq "${#EXPECTED_RGS[@]}"
else
  DOMAIN="$(read_json "print(inv['identity_domain'])")"
  for slug in $ENV_SLUGS; do
    USER="$(read_json "print(data['identity_summary']['value']['developers']['$slug']['username'])")"
    PROJECT="$(read_json "print(data['identity_summary']['value']['developers']['$slug']['project'])")"
    PASSWORD="$(read_json "print(data['initial_passwords']['value']['$USER'])")"
    count="$(openstack_as_identity "$USER" "$PASSWORD" "$PROJECT" "$DOMAIN" \
      server list -f value -c ID 2>/dev/null | wc -l)"
    check "I3" "$slug identity sees its two VMs" test "$count" -eq 2
    unset PASSWORD
  done

  for first in "${SLUG_ARRAY[@]}"; do
    USER="$(read_json "print(data['identity_summary']['value']['developers']['$first']['username'])")"
    PASSWORD="$(read_json "print(data['initial_passwords']['value']['$USER'])")"
    for second in "${SLUG_ARRAY[@]}"; do
      [[ "$first" == "$second" ]] && continue
      OTHER_PROJECT="$(read_json "print(data['identity_summary']['value']['developers']['$second']['project'])")"
      check_blocked "I3" "$first cannot authenticate to $second project" \
        openstack_as_identity "$USER" "$PASSWORD" "$OTHER_PROJECT" "$DOMAIN" token issue
    done
    unset PASSWORD
  done

  LEAD_SLUG="$(read_json "print(sorted(data['identity_summary']['value']['leads'])[0])")"
  LEAD_USER="$(read_json "print(data['identity_summary']['value']['leads']['$LEAD_SLUG']['username'])")"
  LEAD_PASSWORD="$(read_json "print(data['initial_passwords']['value']['$LEAD_USER'])")"
  for slug in $ENV_SLUGS; do
    PROJECT="$(read_json "print(data['identity_summary']['value']['developers']['$slug']['project'])")"
    count="$(openstack_as_identity "$LEAD_USER" "$LEAD_PASSWORD" "$PROJECT" "$DOMAIN" \
      server list -f value -c ID 2>/dev/null | wc -l)"
    check "I3" "$LEAD_SLUG sees both $slug VMs" test "$count" -eq 2
  done
  MGMT_PROJECT="$(read_json "print(inv['management_project_name'])")"
  count="$(openstack_as_identity "$LEAD_USER" "$LEAD_PASSWORD" "$MGMT_PROJECT" "$DOMAIN" \
    server list -f value -c ID 2>/dev/null | wc -l)"
  check "I3" "$LEAD_SLUG sees the management VM" test "$count" -eq 1
  unset LEAD_PASSWORD
fi

printf '\n%s== Network isolation ==%s\n' "$C_HEAD" "$C_RESET"
if ((${#SLUG_ARRAY[@]} >= 2)); then
  for A in "${SLUG_ARRAY[@]}"; do
    A_IP="$(read_json "print(inv['environments']['$A']['moodle_ips'][0])")"
    A_LB="$(read_json "print(inv['environments']['$A']['load_balancer'])")"
    check "I2/I4" "$A can reach its own load balancer" \
      on_node "$A_IP" "curl -fsS --max-time 6 'http://$A_LB/healthz.php'"
    for B in "${SLUG_ARRAY[@]}"; do
      [[ "$A" == "$B" ]] && continue
      B_IP="$(read_json "print(inv['environments']['$B']['moodle_ips'][0])")"
      check_blocked "I2/I4" "$A cannot ping $B" \
        on_node "$A_IP" "ping -c 2 -W 3 '$B_IP'"
      check_blocked "I2/I4" "$A cannot reach $B over SSH" \
        on_node "$A_IP" "timeout 6 bash -c '</dev/tcp/$B_IP/22'"
      check_blocked "I2/I4" "$A cannot reach $B over HTTP" \
        on_node "$A_IP" "curl -fsS --max-time 6 'http://$B_IP/healthz.php'"
    done
  done
else
  record FAIL "I2/I4" "at least two developer environments exist"
fi

printf '\n%s== Public exposure ==%s\n' "$C_HEAD" "$C_RESET"
if [[ "$CLOUD" == "azure" ]]; then
  mapfile -t PUBLIC_IP_NAMES < <(
    az network public-ip list \
      --query "[?tags.project=='techsprint' && tags.environment=='testing'].name" -o tsv
  )
  check "I4" "exactly one project public IP exists" \
    test "${#PUBLIC_IP_NAMES[@]}" -eq 1
  PUBLIC_NAME="${PUBLIC_IP_NAMES[0]:-}"
  check "I4" "the public IP belongs to the jump host" \
    test "${PUBLIC_NAME#*jump}" != "$PUBLIC_NAME"
else
  MGMT_PROJECT="$(read_json "print(inv['management_project_id'])")"
  count="$(openstack floating ip list --project "$MGMT_PROJECT" \
    -f value -c 'Floating IP Address' 2>/dev/null | wc -l)"
  check "I2" "management project has one floating IP" test "$count" -eq 1
  for slug in $ENV_SLUGS; do
    PROJECT="$(read_json "print(inv['environments']['$slug']['project_id'])")"
    count="$(openstack floating ip list --project "$PROJECT" \
      -f value -c 'Floating IP Address' 2>/dev/null | wc -l)"
    check "I2" "$slug project has no floating IP" test "$count" -eq 0
  done
fi

printf '\n%s\n' "--------------------------------------------------------------------------"
printf '  %-6s %-7s %s\n' "RESULT" "RUBRIC" "CHECK"
for row in "${ROWS[@]}"; do
  IFS='|' read -r result rubric label <<< "$row"
  printf '  %-6s %-7s %s\n' "$result" "$rubric" "$label"
done
printf '%s\n' "--------------------------------------------------------------------------"
printf '  %d passed, %d failed  (cloud=%s, run at %s)\n\n' \
  "$PASS" "$FAIL" "$CLOUD" "$(date -Is)"

((FAIL == 0)) || exit 1
printf '  Capture this table for the report'"'"'s Testing section.\n\n'

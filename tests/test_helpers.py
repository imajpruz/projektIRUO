from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

from lib import openstack_stages, parse_users, render_inventory


def terraform_output(value: object) -> dict:
    return {"value": value}


class CsvParserTests(unittest.TestCase):
    def parse(self, content: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "users.csv")
            path.write_text(content, encoding="utf-8")
            return parse_users.parse(path, 10)

    def test_diacritics_roles_and_networks(self) -> None:
        result = self.parse(
            "ime;prezime;rola\n"
            "Đurđa;Šarić;developer\n"
            "Ivan;Ivić;developer\n"
            "Ana;Anić;devops_lead\n"
        )
        self.assertEqual([user["slug"] for user in result["developers"]], ["durdas", "ivani"])
        self.assertEqual(result["developers"][0]["vnet_cidr"], "10.10.0.0/16")
        self.assertEqual(result["developers"][1]["subnet_app_cidr"], "10.11.1.0/24")

    def test_invalid_role_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "role"):
            self.parse(
                "ime;prezime;rola\n"
                "Luka;Lukic;devloper\n"
                "Ana;Anic;devops_lead\n"
            )

    def test_slug_collision_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "same resource name"):
            self.parse(
                "ime;prezime;rola\n"
                "Luka;Lukic;developer\n"
                "Luka;Lazic;developer\n"
                "Ana;Anic;devops_lead\n"
            )

    def test_missing_lead_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "no devops_lead"):
            self.parse(
                "ime;prezime;rola\n"
                "Luka;Lukic;developer\n"
                "Marko;Markic;developer\n"
            )


class OpenStackStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.key = self.root / "id_ed25519"
        self.key.write_text("test-private-key\n", encoding="utf-8")

        self.settings = {
            "project_name": "techsprint",
            "environment": "testing",
            "environment_short": "test",
            "external_network_id": "00000000-0000-0000-0000-000000000001",
            "external_network_name": "provider-datacentre",
            "storage_network_id": "00000000-0000-0000-0000-000000000002",
            "image_name": "rhel8",
            "jump_flavor_name": "default",
            "mgmt_cidr": "10.100.0.0/24",
            "dns_nameservers": ["8.8.8.8"],
            "admin_source_ip": "192.0.2.10/32",
            "admin_username": "cloud-user",
            "moodle_instance_count": 2,
            "data_disk_size_gb": 32,
            "file_share_size_gb": 5,
            "manila_share_type": "techsprint-cephfs",
        }
        bootstrap = {
            "domain_name": "TechSprint",
            "management_project": {"id": "mgmt-id", "name": "proj-techsprint-test-mgmt"},
            "developer_projects": {
                "marion": {
                    "id": "dev-id",
                    "name": "proj-techsprint-test-marion",
                    "developer": {
                        "display_name": "Mario Nikolis",
                        "username": "mario.nikolis",
                        "subnet_app_cidr": "10.10.1.0/24",
                    },
                }
            },
            "environment_secrets": {
                "marion": {
                    "database_password": "db-secret",
                    "moodle_admin_password": "admin-secret",
                    "object_username": "svc-techsprint-test-marion-swift",
                    "object_password": "object-secret",
                }
            },
            "application_flavor_name": "techsprint.2c4r",
            "load_balancer_flavor_id": "lb-flavor-id",
            "ssh": {"private_key_path": str(self.key), "public_key": "ssh-ed25519 test"},
            "settings": self.settings,
        }
        self.bootstrap = self.root / "bootstrap.json"
        self.bootstrap.write_text(
            json.dumps(
                {
                    "bootstrap_data": terraform_output(bootstrap),
                    "identity_summary": terraform_output({"developers": {}}),
                    "initial_passwords": terraform_output(
                        {"mario.nikolis": "developer-secret"}
                    ),
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_environment_and_management_vars_are_private(self) -> None:
        env_vars = self.root / "environment-vars.json"
        openstack_stages.environment_vars(
            Namespace(
                bootstrap_output=self.bootstrap,
                slug="marion",
                auth_url="https://openstack.example/v3",
                out=env_vars,
            )
        )
        data = json.loads(env_vars.read_text(encoding="utf-8"))
        self.assertEqual(data["developer"]["username"], "mario.nikolis")
        self.assertEqual(data["object_username"], "svc-techsprint-test-marion-swift")
        self.assertNotEqual(data["object_password"], "developer-secret")
        self.assertEqual(data["settings"]["storage_network_id"], self.settings["storage_network_id"])
        self.assertEqual(os.stat(env_vars).st_mode & 0o777, 0o600)

        environment_dir = self.root / "environments"
        environment_dir.mkdir()
        (environment_dir / "marion.json").write_text(
            json.dumps(
                {
                    "management_attachment": terraform_output(
                        {
                            "network_id": "network-id",
                            "subnet_id": "subnet-id",
                            "jump_fixed_ip": "10.10.1.253",
                        }
                    )
                }
            ),
            encoding="utf-8",
        )
        management_vars = self.root / "management-vars.json"
        openstack_stages.management_vars(
            Namespace(
                bootstrap_output=self.bootstrap,
                environment_output_dir=environment_dir,
                out=management_vars,
            )
        )
        data = json.loads(management_vars.read_text(encoding="utf-8"))
        self.assertEqual(data["developer_networks"]["marion"]["network_id"], "network-id")
        self.assertEqual(os.stat(management_vars).st_mode & 0o777, 0o600)


class InventoryTests(unittest.TestCase):
    def test_missing_private_key_is_rejected(self) -> None:
        data = {
            "inventory_data": terraform_output(
                {
                    "jump_host": "192.0.2.1",
                    "admin_username": "cloud-user",
                    "ssh_key": "/does/not/exist",
                    "environments": {},
                }
            )
        }
        with self.assertRaisesRegex(ValueError, "private key not found"):
            render_inventory.build_inventory("openstack", data)

    def test_azure_inventory_uses_canonical_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory, "id_ed25519")
            key.write_text("private-key\n", encoding="utf-8")
            environment = {
                "display_name": "Mario Nikolis",
                "moodle_ips": ["10.10.1.4", "10.10.1.5"],
                "subnet_cidr": "10.10.1.0/24",
                "load_balancer": "10.10.1.250",
                "database_password": "db",
                "moodle_admin_password": "admin",
                "blob_storage_account": "stbtechsprinttest1234",
                "file_storage_account": "stftechsprinttest1234",
                "file_storage_key": "key",
                "blob_container": "moodle-files",
                "file_share": "moodle-backups",
                "identity_client_id": "client-id",
            }
            data = {
                "inventory_data": terraform_output(
                    {
                        "jump_host": "192.0.2.1",
                        "admin_username": "techsprint",
                        "ssh_key": str(key),
                        "environments": {"marion": environment},
                    }
                )
            }
            inventory = render_inventory.build_inventory("azure", data)
            self.assertEqual(inventory.count("stbtechsprinttest1234"), 2)
            self.assertEqual(inventory.count("stftechsprinttest1234"), 2)
            self.assertIn("is_db_primary: true", inventory)
            self.assertIn("is_db_primary: false", inventory)


class RepositoryContractTests(unittest.TestCase):
    def test_health_endpoint_checks_all_dependencies(self) -> None:
        template = Path("ansible/roles/moodle/templates/healthz.php.j2").read_text()
        for check in (
            "moodle_config",
            "data_disk",
            "object_storage",
            "file_storage",
            "database",
        ):
            self.assertIn(check, template)
        self.assertIn("200 : 503", template)

    def test_rclone_mount_is_apache_owned_and_not_world_writable(self) -> None:
        tasks = Path("ansible/roles/storage/tasks/main.yml").read_text()
        self.assertIn("User={{ moodle_user }}", tasks)
        self.assertIn("Group={{ moodle_group }}", tasks)
        self.assertIn("--dir-perms 0770", tasks)
        self.assertIn("--file-perms 0660", tasks)
        self.assertNotIn("--dir-perms 0777", tasks)
        self.assertNotIn("--file-perms 0666", tasks)
        self.assertIn("file-mode: 0660", tasks)
        self.assertIn("dir-mode: 0770", tasks)
        self.assertNotIn("default-permission: 0777", tasks)

    def test_azure_storage_is_split_and_network_restricted(self) -> None:
        terraform = Path("iac/azure/modules/developer-env/main.tf").read_text()
        self.assertIn('resource "azurerm_storage_account" "blob"', terraform)
        self.assertIn('resource "azurerm_storage_account" "files"', terraform)
        self.assertEqual(terraform.count('default_action             = "Deny"'), 2)
        self.assertIn('service_endpoints    = ["Microsoft.Storage"]', terraform)

    def test_azure_jump_restricts_private_outbound_traffic(self) -> None:
        terraform = Path("iac/azure/modules/hub/main.tf").read_text()
        self.assertIn('resource "azurerm_network_security_rule" "jump_ssh_out_to_spokes"', terraform)
        self.assertIn('resource "azurerm_network_security_rule" "jump_http_out_to_spokes"', terraform)
        self.assertIn('resource "azurerm_network_security_rule" "jump_deny_other_spoke_out"', terraform)
        self.assertIn('destination_address_prefix  = "10.0.0.0/8"', terraform)

    def test_openstack_swift_uses_a_dedicated_identity(self) -> None:
        terraform = Path("iac/openstack/main.tf").read_text()
        outputs = Path("iac/openstack/outputs.tf").read_text()
        self.assertIn('resource "openstack_identity_user_v3" "object_storage"', terraform)
        self.assertIn("openstack_identity_user_v3.object_storage[slug].name", outputs)
        self.assertIn("random_password.object_storage[slug].result", outputs)
        self.assertNotIn(
            "object_password       = random_password.user[slug].result", outputs
        )

    def test_ci_checks_format_without_rewriting(self) -> None:
        workflow = Path(".github/workflows/validate.yml").read_text()
        self.assertIn("fmt -check -recursive", workflow)
        makefile = Path("Makefile").read_text()
        self.assertIn("lint: fmt-check validate test", makefile)

    def test_destroy_never_synthesizes_saved_user_inputs(self) -> None:
        deploy = Path("deploy.sh").read_text()
        self.assertIn("refusing to synthesize destroy inputs", deploy)
        self.assertNotIn('cp "$destroy_users" "$saved_users"', deploy)

    def test_management_destroy_inputs_survive_clean(self) -> None:
        helper = Path("lib/deploy_openstack.sh").read_text()
        self.assertIn(
            'OS_MANAGEMENT_VARS="$OS_MANAGEMENT_STACK/deployment.auto.tfvars.json"',
            helper,
        )
        self.assertIn('if [[ ! -f "$OS_MANAGEMENT_VARS" ]]', helper)
        clean_recipe = Path("Makefile").read_text().split("clean:", 1)[1]
        self.assertNotIn("users.auto.tfvars.json", clean_recipe)

    def test_storage_probe_preserves_failure_status(self) -> None:
        verifier = Path("lib/verify.sh").read_text()
        self.assertEqual(verifier.count("trap \\\"rm -f --"), 2)
        script = (
            'set -e; p="$1/.verify-$$"; '
            'trap \'rm -f -- "$p"\' EXIT; '
            'printf ok >"$p"; grep -qx ok "$p"'
        )
        with tempfile.TemporaryDirectory() as directory:
            success = subprocess.run(
                ["sh", "-c", script, "probe", directory],
                check=False,
                capture_output=True,
            )
            self.assertEqual(success.returncode, 0)
            self.assertEqual(list(Path(directory).glob(".verify-*")), [])
        failure = subprocess.run(
            ["sh", "-c", script, "probe", "/does/not/exist"],
            check=False,
            capture_output=True,
        )
        self.assertNotEqual(failure.returncode, 0)

    def test_isolation_uses_all_ordered_pairs_and_protocols(self) -> None:
        verifier = Path("lib/verify.sh").read_text()
        self.assertIn('for A in "${SLUG_ARRAY[@]}"', verifier)
        self.assertIn('for B in "${SLUG_ARRAY[@]}"', verifier)
        self.assertIn('for first in "${SLUG_ARRAY[@]}"', verifier)
        self.assertIn('for second in "${SLUG_ARRAY[@]}"', verifier)
        self.assertIn("cannot ping", verifier)
        self.assertIn("cannot reach $B over SSH", verifier)
        self.assertIn("cannot reach $B over HTTP", verifier)

    def test_azure_rbac_rejects_extra_assignments(self) -> None:
        verifier = Path("lib/verify.sh").read_text()
        self.assertIn("$slug identity has no additional assignments", verifier)
        self.assertIn("$LEAD_SLUG has no assignments outside TechSprint", verifier)

    def test_moodle_install_has_recovery_paths(self) -> None:
        tasks = Path("ansible/roles/moodle/tasks/main.yml").read_text()
        self.assertIn("Check the successful-install marker", tasks)
        self.assertIn("Restore a missing config for a complete database", tasks)
        self.assertIn("Remove an incomplete Moodle database", tasks)
        self.assertIn("Recreate a clean Moodle database", tasks)
        self.assertIn("Check final Moodle records", tasks)
        self.assertIn("registrationpending", tasks)
        self.assertIn("Run the Moodle CLI installer on the primary node", tasks)
        self.assertIn("Record a successful Moodle installation", tasks)
        self.assertIn("argv:", tasks)
        self.assertIn("/var/lib/techsprint-moodle-installed", tasks)

    def test_selinux_and_collection_dependencies_are_pinned(self) -> None:
        packages = Path("ansible/roles/common/defaults/main.yml").read_text()
        self.assertIn("policycoreutils-python-utils", packages)
        self.assertIn("python3-libsemanage", packages)
        requirements = Path("ansible/requirements.yml").read_text()
        self.assertEqual(requirements.count("version:"), 3)
        install = Path(".cursor/install.sh").read_text()
        self.assertIn('AZURE_CLI_VERSION="2.89.1"', install)
        self.assertIn('"azure-cli=${AZURE_CLI_VERSION}-1~${VERSION_CODENAME}"', install)

    def test_cloud_init_degraded_status_and_route_retries(self) -> None:
        site = Path("ansible/site.yml").read_text()
        self.assertIn("cloud_init_wait.rc not in [0, 2]", site)
        management = Path("iac/openstack/management/main.tf").read_text()
        application = Path(
            "iac/openstack/modules/rhosp-developer-env/cloud-init.yaml.tftpl"
        ).read_text()
        self.assertIn("Restart=on-failure", management)
        self.assertIn("Restart=on-failure", application)


class CliContractTests(unittest.TestCase):
    def test_plan_and_destroy_are_mutually_exclusive(self) -> None:
        result = subprocess.run(
            ["bash", "deploy.sh", "--cloud", "azure", "--plan-only", "--destroy"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be used together", result.stderr)

    def test_destroy_does_not_create_missing_saved_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib").mkdir()
            (root / "iac/azure").mkdir(parents=True)
            (root / "ansible/inventory").mkdir(parents=True)
            shutil.copy("deploy.sh", root / "deploy.sh")
            shutil.copy("lib/deploy_openstack.sh", root / "lib/deploy_openstack.sh")
            shutil.copy("lib/parse_users.py", root / "lib/parse_users.py")
            csv = root / "users.csv"
            csv.write_text(
                "ime;prezime;rola\n"
                "Mario;Nikolis;developer\n"
                "Andrija;Maric;developer\n"
                "Ivan;Majpruz;devops_lead\n",
                encoding="utf-8",
            )

            mock_bin = root / "bin"
            mock_bin.mkdir()
            terraform = mock_bin / "terraform"
            terraform.write_text(
                '#!/bin/sh\nprintf \'{"terraform_version":"1.9.8"}\\n\'\n',
                encoding="utf-8",
            )
            azure = mock_bin / "az"
            azure.write_text("#!/bin/sh\nprintf 'test-subscription\\n'\n", encoding="utf-8")
            terraform.chmod(0o755)
            azure.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env['PATH']}"
            result = subprocess.run(
                [
                    "bash",
                    str(root / "deploy.sh"),
                    "--csv",
                    str(csv),
                    "--cloud",
                    "azure",
                    "--destroy",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=env,
                cwd=root,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to synthesize destroy inputs", result.stderr)
            self.assertFalse((root / "iac/azure/users.auto.tfvars.json").exists())


if __name__ == "__main__":
    unittest.main()

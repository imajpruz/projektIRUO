#!/usr/bin/env python3
"""Bridge staged OpenStack Terraform roots without exposing secrets.

OpenStack creates Nova, Cinder, Swift, and Manila resources in the token's
project. A dynamic number of projects therefore cannot share one Terraform
provider configuration. deploy.sh applies one workspace per developer, and
this helper passes only the required bootstrap outputs between those stages.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def output_value(data: dict, name: str):
    try:
        return data[name]["value"]
    except KeyError as exc:
        raise SystemExit(f"{name!r} missing from Terraform output {sorted(data)}") from exc


def write_private(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    path.chmod(0o600)


def environment_vars(args: argparse.Namespace) -> None:
    bootstrap = output_value(read_json(args.bootstrap_output), "bootstrap_data")
    try:
        project = bootstrap["developer_projects"][args.slug]
        secrets = bootstrap["environment_secrets"][args.slug]
    except KeyError as exc:
        raise SystemExit(f"developer {args.slug!r} missing from bootstrap output") from exc

    payload = {
        "target_slug": args.slug,
        "target_project_id": project["id"],
        "target_project_name": project["name"],
        "developer": project["developer"],
        "management_project_id": bootstrap["management_project"]["id"],
        "identity_domain_name": bootstrap["domain_name"],
        "application_flavor_name": bootstrap["application_flavor_name"],
        "load_balancer_flavor_id": bootstrap["load_balancer_flavor_id"],
        "ssh_public_key": bootstrap["ssh"]["public_key"],
        "settings": bootstrap["settings"],
        "database_password": secrets["database_password"],
        "moodle_admin_password": secrets["moodle_admin_password"],
        "object_auth_url": args.auth_url,
        "object_username": secrets["object_username"],
        "object_password": secrets["object_password"],
    }
    write_private(args.out, payload)


def environment_output_files(directory: Path) -> list[Path]:
    files = sorted(directory.glob("*.json"))
    if not files:
        raise SystemExit(f"no environment outputs found in {directory}")
    return files


def management_vars(args: argparse.Namespace) -> None:
    bootstrap = output_value(read_json(args.bootstrap_output), "bootstrap_data")
    developer_networks: dict[str, dict] = {}
    for path in environment_output_files(args.environment_output_dir):
        developer_networks[path.stem] = output_value(
            read_json(path), "management_attachment"
        )

    payload = {
        "target_project_id": bootstrap["management_project"]["id"],
        "developer_networks": developer_networks,
        "ssh_public_key": bootstrap["ssh"]["public_key"],
        "settings": bootstrap["settings"],
    }
    write_private(args.out, payload)


def merge_outputs(args: argparse.Namespace) -> None:
    bootstrap_output = read_json(args.bootstrap_output)
    bootstrap = output_value(bootstrap_output, "bootstrap_data")
    management_output = read_json(args.management_output)
    management = output_value(management_output, "inventory_data")

    environments: dict[str, dict] = {}
    inventory_environments: dict[str, dict] = {}
    for path in environment_output_files(args.environment_output_dir):
        data = read_json(path)
        environments[path.stem] = output_value(data, "environment")
        inventory_environments[path.stem] = output_value(data, "inventory_data")

    merged = {
        "environments": {
            "sensitive": False,
            "type": ["map", "dynamic"],
            "value": environments,
        },
        "inventory_data": {
            "sensitive": True,
            "type": ["object", {}],
            "value": {
                "jump_host": management["jump_host"],
                "jump_private_ip": management["jump_private_ip"],
                "admin_username": management["admin_username"],
                "ssh_key": bootstrap["ssh"]["private_key_path"],
                "identity_domain": bootstrap["domain_name"],
                "management_project_id": bootstrap["management_project"]["id"],
                "management_project_name": bootstrap["management_project"]["name"],
                "environments": inventory_environments,
            },
        },
        "identity_summary": bootstrap_output["identity_summary"],
        "initial_passwords": bootstrap_output["initial_passwords"],
    }
    write_private(args.out, merged)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    environment = subparsers.add_parser("environment-vars")
    environment.add_argument("--bootstrap-output", type=Path, required=True)
    environment.add_argument("--slug", required=True)
    environment.add_argument("--auth-url", required=True)
    environment.add_argument("--out", type=Path, required=True)
    environment.set_defaults(func=environment_vars)

    management = subparsers.add_parser("management-vars")
    management.add_argument("--bootstrap-output", type=Path, required=True)
    management.add_argument("--environment-output-dir", type=Path, required=True)
    management.add_argument("--out", type=Path, required=True)
    management.set_defaults(func=management_vars)

    merge = subparsers.add_parser("merge")
    merge.add_argument("--bootstrap-output", type=Path, required=True)
    merge.add_argument("--management-output", type=Path, required=True)
    merge.add_argument("--environment-output-dir", type=Path, required=True)
    merge.add_argument("--out", type=Path, required=True)
    merge.set_defaults(func=merge_outputs)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

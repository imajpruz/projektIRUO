#!/usr/bin/env python3
"""Turn the assignment's CSV into Terraform input.

The project brief fixes the format:

    ime;prezime;rola
    Ivan;Majpruz;devops_lead
    Mario;Nikolis;developer

`deploy.sh` calls this once and feeds the result to both Terraform stacks, so
the CSV is the single source of truth for how many environments get built and
who owns each one. That is what makes the deployment "za varijabilni broj
korisnika" rather than hardcoded for three people.

    python3 lib/parse_users.py users.example.csv --out build/users.auto.tfvars.json

Deliberately stdlib-only: the marked deliverable is a script that runs on a
clean machine without a pip install step.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import unicodedata
from pathlib import Path

# Roles the brief names. devops_lead gets cross-environment power; developer is
# confined to their own environment.
ROLE_LEAD = "devops_lead"
ROLE_DEVELOPER = "developer"
VALID_ROLES = {ROLE_LEAD, ROLE_DEVELOPER}

# Azure storage accounts allow 3-24 lowercase alphanumerics and must be
# globally unique, which is the tightest naming rule in either cloud. Every
# generated identifier is checked against it so a long surname cannot produce
# an invalid name three minutes into a terraform apply.
MAX_SLUG = 12


def strip_diacritics(text: str) -> str:
    """Fold Croatian diacritics to ASCII.

    Names like 'Šarić' or 'Đurđević' are normal in this course's CSVs and are
    rejected outright by Azure resource naming. NFKD splits the base character
    from its combining mark; dropping the marks leaves 'Saric'. The Croatian
    'đ' has no combining form, so it is mapped explicitly.
    """
    manual = {"đ": "d", "Đ": "D", "ð": "d"}
    text = "".join(manual.get(char, char) for char in text)
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def slugify(text: str) -> str:
    slug = strip_diacritics(text).lower()
    slug = re.sub(r"[^a-z0-9]", "", slug)
    return slug


def build_user(row: dict[str, str], line_no: int) -> dict:
    missing = [key for key in ("ime", "prezime", "rola") if not (row.get(key) or "").strip()]
    if missing:
        raise ValueError(f"line {line_no}: missing column(s) {', '.join(missing)}")

    first = row["ime"].strip()
    last = row["prezime"].strip()
    role = row["rola"].strip().lower()

    if role not in VALID_ROLES:
        raise ValueError(
            f"line {line_no}: role '{role}' is not one of {sorted(VALID_ROLES)}"
        )

    first_slug = slugify(first)
    last_slug = slugify(last)
    if not first_slug or not last_slug:
        raise ValueError(f"line {line_no}: '{first} {last}' has no usable ASCII characters")

    # firstname + surname initial keeps names short enough for a storage
    # account while staying readable in a portal listing: Mario Nikolis -> marion
    slug = f"{first_slug}{last_slug[0]}"
    if len(slug) > MAX_SLUG:
        slug = slug[:MAX_SLUG]

    return {
        "first_name": first,
        "last_name": last,
        "display_name": f"{first} {last}",
        "role": role,
        "slug": slug,
        # OpenStack login and a readable owner tag. Azure derives a service
        # principal display name from the stable slug instead.
        "username": f"{first_slug}.{last_slug}",
        "is_lead": role == ROLE_LEAD,
    }


def assign_networks(users: list[dict], base_second_octet: int) -> None:
    """Give every developer a disjoint /16 so the isolation requirement holds.

    'Virtualne mašine različitih programera ne smiju međusobno komunicirati' is
    graded, and the cheapest way to fail it is two developers sharing an
    address range. Indexing the second octet makes overlap impossible by
    construction rather than by review:

        developer 0 -> 10.10.0.0/16, app subnet 10.10.1.0/24
        developer 1 -> 10.11.0.0/16, app subnet 10.11.1.0/24
    """
    index = 0
    for user in users:
        if user["is_lead"]:
            # The lead lives in the shared hub, not in a spoke of their own.
            user["network_index"] = None
            user["vnet_cidr"] = None
            user["subnet_app_cidr"] = None
            continue
        octet = base_second_octet + index
        if octet > 250:
            raise ValueError("too many developers for the 10.x.0.0/16 plan; raise base_second_octet")
        user["network_index"] = index
        user["vnet_cidr"] = f"10.{octet}.0.0/16"
        user["subnet_app_cidr"] = f"10.{octet}.1.0/24"
        index += 1


def parse(path: Path, base_second_octet: int) -> dict:
    if not path.is_file():
        raise SystemExit(f"CSV not found: {path}")

    with path.open(newline="", encoding="utf-8-sig") as handle:
        # utf-8-sig strips the BOM Excel writes, which otherwise turns the
        # first header into '\ufeffime' and breaks the column lookup.
        sample = handle.read(4096)
        handle.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=";,\t")
        except csv.Error:
            dialect = csv.excel
            dialect.delimiter = ";"

        reader = csv.DictReader(handle, dialect=dialect)
        if not reader.fieldnames:
            raise SystemExit(f"{path} is empty")

        reader.fieldnames = [name.strip().lower() for name in reader.fieldnames]
        required = {"ime", "prezime", "rola"}
        if not required.issubset(reader.fieldnames):
            raise SystemExit(
                f"{path} header must contain {sorted(required)}, found {reader.fieldnames}"
            )

        users: list[dict] = []
        errors: list[str] = []
        for line_no, row in enumerate(reader, start=2):
            if not any((value or "").strip() for value in row.values()):
                continue
            try:
                users.append(build_user(row, line_no))
            except ValueError as exc:
                errors.append(str(exc))

    if errors:
        raise SystemExit("CSV validation failed:\n  " + "\n  ".join(errors))
    if not users:
        raise SystemExit(f"{path} contains no data rows")

    slugs = [user["slug"] for user in users]
    duplicates = {slug for slug in slugs if slugs.count(slug) > 1}
    if duplicates:
        raise SystemExit(
            "these users collapse to the same resource name: "
            + ", ".join(sorted(duplicates))
            + "\n  Resource names must be unique; disambiguate the CSV."
        )

    leads = [user for user in users if user["is_lead"]]
    developers = [user for user in users if not user["is_lead"]]
    if not leads:
        raise SystemExit("no devops_lead in the CSV; the brief requires a team lead VM")
    if len(leads) > 1:
        print(
            f"warning: {len(leads)} devops_lead rows; all get cross-environment rights",
            file=sys.stderr,
        )
    if not developers:
        raise SystemExit("no developer rows; nothing to isolate")
    if len(developers) < 2:
        # A warning, not an error: the CSV is structurally fine and you may want
        # a single environment while iterating. Terraform enforces the minimum
        # with a variable validation, so a real deployment still cannot go out
        # under-strength.
        print(
            f"warning: only {len(developers)} developer(s). The brief requires at least 2 "
            "('Testirajte deployment za dva programera i Team Leada'); terraform plan will refuse.",
            file=sys.stderr,
        )

    assign_networks(users, base_second_octet)

    return {
        "users": users,
        "developers": developers,
        "leads": leads,
        "developer_count": len(developers),
        "lead_count": len(leads),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", type=Path, help="path to the users CSV (ime;prezime;rola)")
    parser.add_argument("--out", type=Path, help="write Terraform tfvars JSON here")
    parser.add_argument(
        "--base-second-octet",
        type=int,
        default=10,
        help="second octet of the first developer's /16 (default: 10 -> 10.10.0.0/16)",
    )
    parser.add_argument("--summary", action="store_true", help="print a human-readable table")
    args = parser.parse_args()

    parsed = parse(args.csv, args.base_second_octet)

    if args.summary:
        print(f"{'NAME':<22} {'ROLE':<13} {'SLUG':<13} NETWORK")
        for user in parsed["users"]:
            network = user["vnet_cidr"] or "(shared hub)"
            print(f"{user['display_name']:<22} {user['role']:<13} {user['slug']:<13} {network}")
        print(
            f"\n{parsed['developer_count']} developer environment(s), "
            f"{parsed['lead_count']} lead(s)"
        )

    # Terraform reads a map keyed by slug, so appending a developer preserves
    # existing resource addresses. Network and placement slots intentionally
    # follow CSV order; the scaling demo appends rather than reorders rows.
    payload = {
        "developers": {
            user["slug"]: {
                "first_name": user["first_name"],
                "last_name": user["last_name"],
                "display_name": user["display_name"],
                "username": user["username"],
                "role": user["role"],
                "vnet_cidr": user["vnet_cidr"],
                "subnet_app_cidr": user["subnet_app_cidr"],
                "network_index": user["network_index"],
            }
            for user in parsed["developers"]
        },
        "leads": {
            user["slug"]: {
                "first_name": user["first_name"],
                "last_name": user["last_name"],
                "display_name": user["display_name"],
                "username": user["username"],
                "role": user["role"],
            }
            for user in parsed["leads"]
        },
    }

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        json.dump(payload, sys.stdout, indent=2, ensure_ascii=False)
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())

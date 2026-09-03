# TechSprint - Implementacija računarstva u oblaku
#
# Thin wrapper. The real entry point is ./deploy.sh, because the brief requires
# one script; these targets are for development and discovery.

SHELL := /bin/bash
.DEFAULT_GOAL := help
CSV ?= users.example.csv

.PHONY: help check lint test test-csv fmt fmt-check validate openstack-discover \
        plan-azure plan-openstack deploy-azure deploy-openstack deploy-both \
        verify destroy clean

help: ## Show this list
	@echo ""
	@echo "  TechSprint - per-developer Moodle environments on Azure and OpenStack"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Override the users file with CSV=path/to/file.csv"
	@echo "  Start at docs/architecture.md; grading map in docs/rubric-traceability.md"
	@echo ""

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
check: ## Verify tooling, credentials and that tfvars have no placeholders left
	@echo "== tooling =="
	@for tool in terraform ansible-playbook ansible-lint az openstack python3 jq shellcheck; do \
	  printf '  %-18s %s\n' "$$tool" "$$(command -v $$tool 2>/dev/null || echo MISSING)"; \
	done
	@echo "== credentials =="
	@if az account show >/dev/null 2>&1; then \
	  printf '  azure            %s\n' "$$(az account show --query name -o tsv)"; \
	else \
	  printf '  azure            NOT LOGGED IN (run: az login)\n'; \
	fi
	@if [[ -n "$$OS_AUTH_URL" ]]; then \
	  printf '  openstack        %s\n' "$$OS_AUTH_URL"; \
	else \
	  printf '  openstack        OS_AUTH_URL unset (source your RC file)\n'; \
	fi
	@echo "== configuration =="
	@for stack in azure openstack; do \
	  if [[ -f iac/$$stack/terraform.tfvars ]]; then \
	    left=$$(grep -cE '=[[:space:]]*"<' iac/$$stack/terraform.tfvars || true); \
	    printf '  iac/%-12s present, %s placeholder(s) left\n' "$$stack" "$$left"; \
	  else \
	    printf '  iac/%-12s MISSING (cp terraform.tfvars.example terraform.tfvars)\n' "$$stack"; \
	  fi; \
	done

# ------------------------------------------------------------------------------
# Quality gates
# ------------------------------------------------------------------------------
lint: fmt-check validate test ## Everything: terraform, tests, ansible, shell, python
	@echo "== ansible =="
	@ansible-lint ansible/ || exit 1
	@echo "== shell =="
	@shellcheck -S warning deploy.sh lib/*.sh
	@echo "== python =="
	@python3 -m py_compile lib/parse_users.py lib/render_inventory.py
	@rm -rf lib/__pycache__
	@echo ""
	@echo "all checks passed"

fmt: ## Format the Terraform sources
	@terraform -chdir=iac/azure fmt -recursive
	@terraform -chdir=iac/openstack fmt -recursive

fmt-check: ## Check Terraform formatting without changing files
	@terraform -chdir=iac/azure fmt -check -recursive
	@terraform -chdir=iac/openstack fmt -check -recursive

validate: ## Validate both Terraform stacks (no credentials needed)
	@echo "== terraform: azure =="
	@terraform -chdir=iac/azure init -backend=false -input=false >/dev/null
	@terraform -chdir=iac/azure validate
	@echo "== terraform: openstack =="
	@terraform -chdir=iac/openstack init -backend=false -input=false >/dev/null
	@terraform -chdir=iac/openstack validate
	@terraform -chdir=iac/openstack/data init -backend=false -input=false >/dev/null
	@terraform -chdir=iac/openstack/data validate

test: ## Run all offline unit tests
	@python3 -m unittest discover -s tests -v

test-csv: test ## Backwards-compatible alias for the parser tests

# ------------------------------------------------------------------------------
# Discovery
# ------------------------------------------------------------------------------
openstack-discover: ## Print the lab-specific values for iac/openstack/terraform.tfvars
	@command -v openstack >/dev/null || { echo "openstack client not installed"; exit 1; }
	@[[ -n "$$OS_AUTH_URL" ]] || { echo "source your OpenStack RC file first"; exit 1; }
	@echo "== identity =="
	@openstack token issue -f value -c project_id | sed 's/^/  project_id  /'
	@openstack domain list -f value -c ID -c Name | sed 's/^/  domain      /'
	@echo "== external network (external_network_id / _name) =="
	@openstack network list --external -f value -c ID -c Name | sed 's/^/  /'
	@echo "== cloud Linux images (image_name) =="
	@openstack image list --status active -f value -c Name | grep -iE 'rocky|centos|stream|rhel' | sed 's/^/  /' \
	  || echo "  NONE FOUND - see docs/troubleshooting.md"
	@echo "== flavors: need vcpus=2, ram=4096; bootstrap creates one if absent =="
	@openstack flavor list -f value -c Name -c RAM -c VCPUs | awk '$$3==2 && $$2>=4000 {print "  "$$1"  ram="$$2" vcpus="$$3}' \
	  || echo "  none with exactly 2 vCPU / 4 GB - check the full list"
	@echo "== required services =="
	@for svc in compute network image block-storage object-store load-balancer sharev2; do \
	  if openstack catalog list -f value -c Type | grep -qx "$$svc"; then \
	    printf '  OK       %s\n' "$$svc"; \
	  else \
	    printf '  MISSING  %s\n' "$$svc"; \
	  fi; \
	done
	@echo "== quota =="
	@openstack quota show -f table 2>/dev/null || echo "  quota API not exposed to your role"
	@echo ""
	@echo "  All services above are required by this CL110 design."

# ------------------------------------------------------------------------------
# Deployment - thin wrappers over ./deploy.sh
# ------------------------------------------------------------------------------
plan-azure: ## Terraform plan for Azure, creates nothing
	@./deploy.sh --csv $(CSV) --cloud azure --plan-only

plan-openstack: ## Plan OpenStack bootstrap and any already-created project stages
	@./deploy.sh --csv $(CSV) --cloud openstack --plan-only

deploy-azure: ## Full Azure deployment
	@./deploy.sh --csv $(CSV) --cloud azure

deploy-openstack: ## Full OpenStack deployment
	@./deploy.sh --csv $(CSV) --cloud openstack

deploy-both: ## Both clouds, one run
	@./deploy.sh --csv $(CSV) --cloud both

verify: ## Run the rubric-labelled checks against whatever is deployed
	@mkdir -p evidence
	@for cloud in azure openstack; do \
	  if [[ -f build/$$cloud-output.json ]]; then \
	    ./lib/verify.sh --cloud $$cloud | tee evidence/verify-$$cloud.txt; \
	  else \
	    echo "no deployment found for $$cloud"; \
	  fi; \
	done

destroy: ## Tear both clouds down
	@./deploy.sh --csv $(CSV) --cloud both --destroy

clean: ## Remove local build artifacts (keeps terraform state and evidence)
	@rm -rf build lib/__pycache__ ansible/inventory/*.yml
	@rm -f iac/*/tfplan
	@touch ansible/inventory/.gitkeep
	@echo "cleaned"

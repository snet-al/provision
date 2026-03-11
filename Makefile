SHELL := /bin/bash

lint:
	@command -v shellcheck >/dev/null 2>&1 && shellcheck setup.sh orchestrate.sh lib/*.sh tasks/10-system/*.sh tasks/20-identity/*.sh tasks/30-security/*.sh tasks/40-container/*.sh tasks/90-post/*.sh profiles/*.sh tests/*.sh || echo "shellcheck not installed; skipping"
	@command -v shfmt >/dev/null 2>&1 && shfmt -w setup.sh orchestrate.sh lib/*.sh tasks/10-system/*.sh tasks/20-identity/*.sh tasks/30-security/*.sh tasks/40-container/*.sh tasks/90-post/*.sh profiles/*.sh tests/*.sh || echo "shfmt not installed; skipping"

test:
	@bash tests/test_ensure.sh
	@bash tests/test_config.sh
	@bash tests/test_inventory.sh
	@bash tests/test_profiles.sh
	@bash tests/test_mde.sh

validate: lint test

plan:
	@sudo ./setup.sh --profile basic --non-interactive --plan

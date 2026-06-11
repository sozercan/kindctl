SHELL := /bin/bash
TEST_PATTERN ?=

.PHONY: lint test test-integration

lint:
	bash -n bin/kindctl
	bash -n test/run-tests.sh
	bash -n test/run-integration.sh
	python3 test/lint-actions-pinned.py
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck bin/kindctl test/run-tests.sh test/run-integration.sh; else echo "shellcheck not installed; skipping"; fi

test:
	TEST_PATTERN="$(TEST_PATTERN)" test/run-tests.sh

test-integration:
	test/run-integration.sh


.PHONY: install-skill install-cli
install-skill:
	npx --yes skills@latest add "$(CURDIR)" --global --skill kindctl --agent claude-code --agent codex --yes

install-cli:
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(CURDIR)/bin/kindctl" "$(HOME)/.local/bin/kindctl"
	@echo "installed cli symlink: $(HOME)/.local/bin/kindctl -> $(CURDIR)/bin/kindctl"

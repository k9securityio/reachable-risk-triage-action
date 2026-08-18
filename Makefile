SHELL := /bin/bash

ifeq ($(strip $(BUILD_ID)),)
	VCS_REF := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
	BUILD_TIME_UTC := $(shell date +'%Y%m%d-%H%M%S')
	BUILD_ID := $(BUILD_TIME_UTC)-$(VCS_REF)
endif

BUILD_BRANCH := $(shell git symbolic-ref --short HEAD 2>/dev/null || echo detached)

.PHONY: metadata
metadata:
	@echo "Gathering Metadata"
	@echo BUILD_TIME_UTC is $(BUILD_TIME_UTC)
	@echo BUILD_ID is $(BUILD_ID)
	@echo BUILD_BRANCH is $(BUILD_BRANCH)


.PHONY: run-shellcheck
run-shellcheck:
	@echo running shellcheck
	shellcheck scripts/*.sh


# 'copilot-requests' is a real Actions permission that actionlint's permission
# list does not know yet (<=1.7.10) — same false-positive class as zizmor
# <=1.29's 'unknown permission' warn. Re-check the ignore on upgrades.
.PHONY: run-actionlint
run-actionlint:
	@echo running actionlint
	actionlint -ignore 'unknown permission scope "copilot-requests"' \
		.github/workflows/*.yml examples/*.yml


# Audits action.yml + CI workflows (the default collection) and the example
# caller (not a workflow path, so passed explicitly). Findings are a release
# gate: a published action is a supply-chain artifact customers execute with
# secrets in scope.
.PHONY: run-zizmor
run-zizmor:
	@echo running zizmor security audit
	zizmor --min-severity low . examples/dependency-triage.yml


.PHONY: quick
quick: metadata run-shellcheck run-actionlint run-zizmor

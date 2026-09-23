SCRIPTS := $(wildcard scripts/*.sh) $(wildcard templates/*.sh) $(wildcard tools/*.sh)

.PHONY: all check lint fmt fmt-check sync sync-check help

all: check sync-check lint

help:
	@echo "make check      - bash -n syntax check of all scripts"
	@echo "make lint       - shellcheck all scripts"
	@echo "make fmt        - format scripts in place with shfmt"
	@echo "make fmt-check  - show shfmt diff without changing files"
	@echo "make sync       - copy the helper block from templates/script-skeleton.sh into scripts/"
	@echo "make sync-check - verify every script carries the current helper block"

check:
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "ok   $$f" || exit 1; done

lint:
	shellcheck -x $(SCRIPTS)

fmt:
	shfmt -i 4 -ci -w $(SCRIPTS)

fmt-check:
	shfmt -i 4 -ci -d $(SCRIPTS)

sync:
	@tools/sync-helpers.sh

sync-check:
	@tools/sync-helpers.sh --check

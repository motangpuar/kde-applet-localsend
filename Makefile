SHELL   := /bin/bash
PLASMOID := plasmoid/io.github.localsend.plasmoid
PACKAGE  := $(PLASMOID)/contents/backend
PYTHON   ?= python3

.DEFAULT_GOAL := help
.PHONY: help test lint backend install uninstall verify run ctl clean

help: ## list targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

test: ## unit + protocol tests (hermetic, no network)
	$(PYTHON) -m unittest discover -s python/tests -t python/tests

lint: ## byte-compile the backend and tests
	$(PYTHON) -m py_compile python/localsendd python/localsendctl
	$(PYTHON) -m compileall -q python/tests

backend: lint ## stage the backend into the plasmoid package
	install -m755 python/localsendd $(PACKAGE)/localsendd
	install -m755 python/localsendctl $(PACKAGE)/localsendctl
	chmod 755 $(PACKAGE)/manage.sh

install: ## stage + install the plasmoid for the current user
	./scripts/install.sh

uninstall: ## remove the plasmoid (pass ARGS=--purge to drop config/history)
	./scripts/uninstall.sh $(ARGS)

verify: test backend ## tests + package layout checks
	@echo "== package layout =="
	@$(PYTHON) -c "import json;json.load(open('$(PLASMOID)/metadata.json'));print('metadata.json ok')"
	@test -f $(PLASMOID)/contents/ui/main.qml && echo "main.qml present"
	@test -f $(PLASMOID)/contents/config/main.xml && echo "config/main.xml present"
	@test -x $(PACKAGE)/manage.sh && echo "backend/manage.sh present"
	@echo "staged: $$(ls $(PACKAGE) | tr '\n' ' ')"

run: ## run the daemon in the foreground (dev)
	$(PYTHON) python/localsendd --idle-exit 0

ctl: ## print the live daemon snapshot
	$(PYTHON) python/localsendctl state

clean: ## drop caches and staged payloads
	rm -rf python/__pycache__ python/tests/__pycache__
	rm -f $(PACKAGE)/localsendd $(PACKAGE)/localsendctl

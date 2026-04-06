SHELL := /bin/bash

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/lib/pr-loop
INSTALL ?= install

.PHONY: install uninstall test

install:
	$(INSTALL) -d "$(BINDIR)" "$(LIBEXECDIR)" "$(LIBEXECDIR)/lib" "$(LIBEXECDIR)/prompts"
	$(INSTALL) -m 0755 pr-loop.sh "$(LIBEXECDIR)/pr-loop.sh"
	$(INSTALL) -m 0755 issue-scan.sh "$(LIBEXECDIR)/issue-scan.sh"
	$(INSTALL) -m 0755 worker.sh "$(LIBEXECDIR)/worker.sh"
	$(INSTALL) -m 0755 statectl.sh "$(LIBEXECDIR)/statectl.sh"
	$(INSTALL) -m 0755 claude-output-filter.sh "$(LIBEXECDIR)/claude-output-filter.sh"
	$(INSTALL) -m 0644 lib/core.sh "$(LIBEXECDIR)/lib/core.sh"
	$(INSTALL) -m 0644 lib/gh.sh "$(LIBEXECDIR)/lib/gh.sh"
	$(INSTALL) -m 0644 prompts/claude-pr-worker.prompt.tmpl "$(LIBEXECDIR)/prompts/claude-pr-worker.prompt.tmpl"
	printf '%s\n' '#!/usr/bin/env bash' 'exec "$(LIBEXECDIR)/pr-loop.sh" "$$@"' >"$(BINDIR)/pr-loop"
	chmod 0755 "$(BINDIR)/pr-loop"

uninstall:
	rm -f "$(BINDIR)/pr-loop"
	rm -rf "$(LIBEXECDIR)"

test:
	./tests/run.sh

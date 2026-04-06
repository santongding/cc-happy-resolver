SHELL := /bin/bash

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/lib/pr-loop
CLAUDE_SKILLSDIR ?= $(HOME)/.claude/skills
CLAUDE_SKILLDIR ?= $(CLAUDE_SKILLSDIR)/cc-happy-resolver
INSTALL ?= install

.PHONY: install uninstall test

install:
	$(INSTALL) -d "$(BINDIR)" "$(LIBEXECDIR)" "$(LIBEXECDIR)/lib" "$(LIBEXECDIR)/prompts" "$(CLAUDE_SKILLDIR)"
	$(INSTALL) -m 0755 pr-loop.sh "$(LIBEXECDIR)/pr-loop.sh"
	$(INSTALL) -m 0755 issue-scan.sh "$(LIBEXECDIR)/issue-scan.sh"
	$(INSTALL) -m 0755 worker.sh "$(LIBEXECDIR)/worker.sh"
	$(INSTALL) -m 0755 statectl.sh "$(LIBEXECDIR)/statectl.sh"
	$(INSTALL) -m 0755 claude-output-filter.sh "$(LIBEXECDIR)/claude-output-filter.sh"
	$(INSTALL) -m 0644 lib/core.sh "$(LIBEXECDIR)/lib/core.sh"
	$(INSTALL) -m 0644 lib/gh.sh "$(LIBEXECDIR)/lib/gh.sh"
	$(INSTALL) -m 0644 prompts/claude-pr-worker.prompt.tmpl "$(LIBEXECDIR)/prompts/claude-pr-worker.prompt.tmpl"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/SKILL.md "$(CLAUDE_SKILLDIR)/SKILL.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/fetch.md "$(CLAUDE_SKILLDIR)/fetch.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/plan.md "$(CLAUDE_SKILLDIR)/plan.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/impl.md "$(CLAUDE_SKILLDIR)/impl.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/review.md "$(CLAUDE_SKILLDIR)/review.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/finished.md "$(CLAUDE_SKILLDIR)/finished.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/next-stage.md "$(CLAUDE_SKILLDIR)/next-stage.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/exit.md "$(CLAUDE_SKILLDIR)/exit.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/record.md "$(CLAUDE_SKILLDIR)/record.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/post.md "$(CLAUDE_SKILLDIR)/post.md"
	$(INSTALL) -m 0644 skills/cc-happy-resolver/gh-helper-commands.md "$(CLAUDE_SKILLDIR)/gh-helper-commands.md"
	printf '%s\n' '#!/usr/bin/env bash' 'exec "$(LIBEXECDIR)/pr-loop.sh" "$$@"' >"$(BINDIR)/pr-loop"
	chmod 0755 "$(BINDIR)/pr-loop"

uninstall:
	rm -f "$(BINDIR)/pr-loop"
	rm -rf "$(LIBEXECDIR)"
	rm -rf "$(CLAUDE_SKILLDIR)"

test:
	./tests/run.sh

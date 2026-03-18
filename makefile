# makefile - xcesppkg
# Assembles a self-contained installer tarball from already-built components.
# Run 'make' in each component project first, then run 'make' here.

include PROJECT

PKG_NAME := xcespkg-$(PRJVERSION)
TARBALL  := $(PKG_NAME).tar.gz

# Built binaries (relative to this makefile's directory)
XCESPSERVER := ../xcespserver/bin/xcespserver
XCESPCLI    := ../xcespcli/bin/xcespcli
XCESPPROC   := ../xcespproc/bin/xcespproc
XCESPWDOG   := ../xcespwdog/bin/xcespwdog

# xcesppy source (Python client library)
XCESPPY_SRC := ../xcesppy/xcesppy

# Schema and rules from xcesptest (symlinks are dereferenced via cp -rL)
SCHEMA_SRC  := ../xcesptest/schema
RULES_SRC   := ../xcesptest/rules

.PHONY: all clean check-bins

all: $(TARBALL)

# Verify all binaries are built before packaging
check-bins:
	@for b in $(XCESPSERVER) $(XCESPCLI) $(XCESPPROC) $(XCESPWDOG); do \
		test -f "$$b" || { echo "ERROR: $$b not found — build the component first"; exit 1; }; \
	done

$(TARBALL): check-bins install.sh services/xcesp.service \
            cfg/xcespserver.ini cfg/xcespproc.ini cfg/xcespwdog.ini \
            cfg/xcespserver.conf python/pyproject.toml
	@echo "Building package $(TARBALL) ..."
	rm -rf $(PKG_NAME)

	# --- Binaries ---
	mkdir -p $(PKG_NAME)/bin
	cp $(XCESPSERVER) $(PKG_NAME)/bin/xcespserver
	cp $(XCESPCLI)    $(PKG_NAME)/bin/xcespcli
	cp $(XCESPPROC)   $(PKG_NAME)/bin/xcespproc
	cp $(XCESPWDOG)   $(PKG_NAME)/bin/xcespwdog

	# --- Config templates ---
	mkdir -p $(PKG_NAME)/cfg
	cp cfg/xcespserver.ini  $(PKG_NAME)/cfg/
	cp cfg/xcespproc.ini    $(PKG_NAME)/cfg/
	cp cfg/xcespwdog.ini    $(PKG_NAME)/cfg/
	cp cfg/xcespserver.conf $(PKG_NAME)/cfg/

	# --- Schema (dereference symlinks so the tarball is self-contained) ---
	mkdir -p $(PKG_NAME)/schema
	cp -rL $(SCHEMA_SRC)/. $(PKG_NAME)/schema/
	find $(PKG_NAME)/schema -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

	# --- Python rules (dereference symlinks) ---
	mkdir -p $(PKG_NAME)/rules/config-to-objects $(PKG_NAME)/rules/status-to-global
	cp -L $(RULES_SRC)/worker.py $(PKG_NAME)/rules/
	cp -L $(RULES_SRC)/config-to-objects/*.py $(PKG_NAME)/rules/config-to-objects/ 2>/dev/null || true
	cp -L $(RULES_SRC)/status-to-global/*.py  $(PKG_NAME)/rules/status-to-global/  2>/dev/null || true
	find $(PKG_NAME)/rules -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

	# --- xcesppy Python library ---
	mkdir -p $(PKG_NAME)/python/xcesppy
	cp python/pyproject.toml $(PKG_NAME)/python/
	cp -r $(XCESPPY_SRC)/. $(PKG_NAME)/python/xcesppy/
	find $(PKG_NAME)/python -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

	# --- Systemd service ---
	mkdir -p $(PKG_NAME)/services
	cp services/xcesp.service $(PKG_NAME)/services/

	# --- Installer script ---
	cp install.sh $(PKG_NAME)/install.sh
	chmod +x $(PKG_NAME)/install.sh

	# --- Create tarball ---
	tar czf $(TARBALL) $(PKG_NAME)
	rm -rf $(PKG_NAME)
	@echo "Package ready: $(TARBALL)"

clean:
	rm -rf $(PKG_NAME) $(TARBALL)

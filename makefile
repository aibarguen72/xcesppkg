# makefile - xcesppkg
# Assembles a self-contained installer tarball from already-built components.
# Run 'make' in each component project first, then run 'make' here.

include PROJECT

PKG_NAME := xcespkg-$(PRJVERSION)
TARBALL  := $(PKG_NAME).tar.gz

# ---------------------------------------------------------------------------
# Component version numbers (read from each project's PROJECT file at parse time)
# ---------------------------------------------------------------------------
ver = $(shell grep PRJVERSION ../$(1)/PROJECT 2>/dev/null | awk -F':=' '{gsub(/ /,"",$$2); print $$2}')

VER_SERVER  := $(call ver,xcespserver)
VER_CLI     := $(call ver,xcespcli)
VER_PROC    := $(call ver,xcespproc)
VER_WDOG    := $(call ver,xcespwdog)
VER_ONRTR   := $(call ver,xcesp-on-rtr)
VER_ONPW    := $(call ver,xcesp-on-pw)
VER_ONXC    := $(call ver,xcesp-on-xc)
VER_MAP     := $(call ver,xcespmap)
VER_SCHEMA  := $(call ver,xcespschema)
VER_CONFIG  := $(call ver,xcespconfig)
VER_PY      := $(call ver,xcesppy)

# ---------------------------------------------------------------------------
# Source paths
# ---------------------------------------------------------------------------

# Binaries
XCESPSERVER := ../xcespserver/bin/xcespserver
XCESPCLI    := ../xcespcli/bin/xcespcli
XCESPPROC   := ../xcespproc/bin/xcespproc
XCESPWDOG   := ../xcespwdog/bin/xcespwdog

# Schema: direct files from xcesptest + each ON library's own schema directory.
# (xcesptest/schema uses broken relative symlinks for on-rtr/on-pw/on-xc —
#  we bypass those and copy from the actual source trees instead.)
SCHEMA_DIRECT := ../xcesptest/schema/domain.schema \
                 ../xcesptest/schema/_types.schema  \
                 ../xcesptest/schema/udpbert.schema  \
                 ../xcesptest/schema/udpbert.status  \
                 ../xcesptest/schema/udptester.schema \
                 ../xcesptest/schema/udptester.status

SCHEMA_ONRTR := ../xcesp-on-rtr/schema
SCHEMA_ONPW  := ../xcesp-on-pw/schema
SCHEMA_ONXC  := ../xcesp-on-xc/schema

# Rules: direct files from xcesptest + each ON library's own rules directory.
RULES_WORKER    := ../xcesptest/rules/worker.py
RULES_C2O_XCTEST := ../xcesptest/rules/config-to-objects
RULES_S2G_XCTEST := ../xcesptest/rules/status-to-global
RULES_ONRTR     := ../xcesp-on-rtr/rules
RULES_ONPW      := ../xcesp-on-pw/rules
RULES_ONXC      := ../xcesp-on-xc/rules

# xcesppy source
XCESPPY_SRC := ../xcesppy/xcesppy

# ---------------------------------------------------------------------------

.PHONY: all clean check-bins

all: $(TARBALL)

# Verify all binaries are built before packaging
check-bins:
	@for b in $(XCESPSERVER) $(XCESPCLI) $(XCESPPROC) $(XCESPWDOG); do \
		test -f "$$b" || { echo "ERROR: $$b not found — build the component first"; exit 1; }; \
	done

$(TARBALL): check-bins install.sh services/xcesp.service \
            scripts/xcesp-activate scripts/xcesp-swap.sh \
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

	# --- Schema ---
	# Direct xcesptest schema files
	mkdir -p $(PKG_NAME)/schema
	cp $(SCHEMA_DIRECT) $(PKG_NAME)/schema/
	# ON library schema directories (copied directly — bypasses broken symlinks)
	mkdir -p $(PKG_NAME)/schema/on-rtr $(PKG_NAME)/schema/on-pw $(PKG_NAME)/schema/on-xc
	cp -r $(SCHEMA_ONRTR)/. $(PKG_NAME)/schema/on-rtr/
	cp -r $(SCHEMA_ONPW)/.  $(PKG_NAME)/schema/on-pw/
	cp -r $(SCHEMA_ONXC)/.  $(PKG_NAME)/schema/on-xc/

	# --- Python rules ---
	mkdir -p $(PKG_NAME)/rules/config-to-objects $(PKG_NAME)/rules/status-to-global
	# Worker dispatcher
	cp $(RULES_WORKER) $(PKG_NAME)/rules/
	# Direct xcesptest rule files (not symlinks: udpbert, udptester)
	find $(RULES_C2O_XCTEST) -maxdepth 1 -type f -name "*.py" \
	    -exec cp {} $(PKG_NAME)/rules/config-to-objects/ \;
	find $(RULES_S2G_XCTEST) -maxdepth 1 -type f -name "*.py" \
	    -exec cp {} $(PKG_NAME)/rules/status-to-global/ \;
	# ON library rules (copied directly from source trees)
	cp $(RULES_ONRTR)/config-to-objects/*.py $(PKG_NAME)/rules/config-to-objects/
	cp $(RULES_ONRTR)/status-to-global/*.py  $(PKG_NAME)/rules/status-to-global/
	cp $(RULES_ONPW)/config-to-objects/*.py  $(PKG_NAME)/rules/config-to-objects/
	cp $(RULES_ONPW)/status-to-global/*.py   $(PKG_NAME)/rules/status-to-global/
	cp $(RULES_ONXC)/config-to-objects/*.py  $(PKG_NAME)/rules/config-to-objects/
	cp $(RULES_ONXC)/status-to-global/*.py   $(PKG_NAME)/rules/status-to-global/
	find $(PKG_NAME)/rules -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

	# --- xcesppy Python library ---
	mkdir -p $(PKG_NAME)/python/xcesppy
	cp python/pyproject.toml $(PKG_NAME)/python/
	cp -r $(XCESPPY_SRC)/. $(PKG_NAME)/python/xcesppy/
	find $(PKG_NAME)/python -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

	# --- Management scripts ---
	mkdir -p $(PKG_NAME)/scripts
	cp scripts/xcesp-activate $(PKG_NAME)/scripts/
	cp scripts/xcesp-swap.sh  $(PKG_NAME)/scripts/
	chmod +x $(PKG_NAME)/scripts/xcesp-activate $(PKG_NAME)/scripts/xcesp-swap.sh

	# --- Systemd service ---
	mkdir -p $(PKG_NAME)/services
	cp services/xcesp.service $(PKG_NAME)/services/

	# --- VERSION file (generated from live PROJECT files) ---
	@{ \
		echo "XCESPKG $(PRJVERSION)"; \
		echo "Built:  $$(date -u '+%Y-%m-%d %H:%M UTC')"; \
		echo ""; \
		printf "%-22s %s\n" "Component" "Version"; \
		printf "%-22s %s\n" "---------" "-------"; \
		printf "%-22s %s\n" "xcespserver"   "$(VER_SERVER)"; \
		printf "%-22s %s\n" "xcespcli"      "$(VER_CLI)"; \
		printf "%-22s %s\n" "xcespproc"     "$(VER_PROC)"; \
		printf "%-22s %s\n" "xcespwdog"     "$(VER_WDOG)"; \
		printf "%-22s %s\n" "xcesp-on-rtr"  "$(VER_ONRTR)"; \
		printf "%-22s %s\n" "xcesp-on-pw"   "$(VER_ONPW)"; \
		printf "%-22s %s\n" "xcesp-on-xc"   "$(VER_ONXC)"; \
		printf "%-22s %s\n" "xcespmap"       "$(VER_MAP)"; \
		printf "%-22s %s\n" "xcespschema"    "$(VER_SCHEMA)"; \
		printf "%-22s %s\n" "xcespconfig"    "$(VER_CONFIG)"; \
		printf "%-22s %s\n" "xcesppy"        "$(VER_PY)"; \
	} > $(PKG_NAME)/VERSION

	# --- Installer script ---
	cp install.sh $(PKG_NAME)/install.sh
	chmod +x $(PKG_NAME)/install.sh

	# --- Create tarball ---
	tar czf $(TARBALL) $(PKG_NAME)
	rm -rf $(PKG_NAME)
	@echo "Package ready: $(TARBALL)"

clean:
	rm -rf $(PKG_NAME) $(TARBALL)

# Battery Threshold — top-level Makefile
#
# Quick start:
#   make doctor         Show what was detected on this system
#   make deps           Check & guide installing kernel modules / repos
#   make build          Compile daemon and bundle extension
#   sudo make install   Install everything (system + user extension)
#   make uninstall      Remove everything

UUID            := battery-threshold@korrnals.github.io
DAEMON_NAME     := battery-thresholdd
VERSION         := $(shell awk '/^version/{gsub(/"/,""); print $$3; exit}' src/daemon/Cargo.toml)
PROJECT_URL     := https://github.com/Korrnals/gnome-battery-threshold

# ─────────────────────────────────────────────────────────────────────────────
# Path detection — auto-pick a writable PREFIX.
# Silverblue/Kinoite/Sericea (atomic Fedora) have read-only /usr; fall back to
# /usr/local. Traditional distros use /usr.
# ─────────────────────────────────────────────────────────────────────────────
IS_RO_USR := $(shell test -w /usr 2>/dev/null && echo no || echo yes)

ifeq ($(PREFIX),)
  ifeq ($(IS_RO_USR),yes)
    PREFIX := /usr/local
  else
    PREFIX := /usr
  endif
endif

LIBEXECDIR      := $(PREFIX)/libexec
DATADIR         := $(PREFIX)/share
SYSCONFDIR      ?= /etc
DBUS_SYSTEM_DIR := $(SYSCONFDIR)/dbus-1/system.d
DBUS_SERVICES   := $(DATADIR)/dbus-1/system-services
POLKIT_DIR      := $(DATADIR)/polkit-1/actions
SYSTEMD_DIR     := $(SYSCONFDIR)/systemd/system
GSCHEMA_DIR     := $(DATADIR)/glib-2.0/schemas

# When invoked via sudo we want the extension to land in the real user's
# home, not /root/. SUDO_USER is set by sudo for this purpose.
REAL_USER    := $(if $(SUDO_USER),$(SUDO_USER),$(USER))

# ─────────────────────────────────────────────────────────────────────────────
# Distrobox detection
# Inside a distrobox container:
#   • $HOME is the container overlay (e.g. ~/.distrobox/box/home), not host home
#   • /usr/local writes via normal sudo don't land on the host FS layer
#   • systemctl must talk to the host
# Solution: route privileged + system commands through distrobox-host-exec and
# resolve REAL_HOME + OS info from the host's /etc/{passwd,os-release}.
# ─────────────────────────────────────────────────────────────────────────────
IS_DISTROBOX := $(shell test -f /run/.containerenv 2>/dev/null && echo yes || echo no)

ifeq ($(IS_DISTROBOX),yes)
  REAL_HOME  := $(shell awk -F: -v u=$(REAL_USER) '$$1==u{print $$6}' \
                    /run/host/etc/passwd 2>/dev/null || echo /var/home/$(REAL_USER))
  HSUDO      := distrobox-host-exec sudo
  HOST_EXEC  := distrobox-host-exec
else
  REAL_HOME  := $(shell getent passwd $(REAL_USER) 2>/dev/null | cut -d: -f6)
  HSUDO      := sudo
  HOST_EXEC  :=
endif

HOST_UID        := $(shell id -u $(REAL_USER) 2>/dev/null || echo 1000)
EXTENSION_DIR   := $(REAL_HOME)/.local/share/gnome-shell/extensions/$(UUID)

CARGO           ?= cargo
BUILD_DIR       := target
GEN_DIR         := $(BUILD_DIR)/generated

# ─────────────────────────────────────────────────────────────────────────────
# acpi_call source.
# Traditional Fedora installs from COPR rhea/acpi_call (DKMS).
# On rpm-ostree atomic, DKMS cannot run in the compose sandbox (writes to
# /var/lib/dkms which is read-only during compose), and no akmod build exists
# for current Fedora releases. We instead build acpi_call.ko out-of-tree
# (inside the distrobox container) and drop it into the host's mutable
# /var/lib/modules/<kver>/extra/, which modprobe picks up after depmod.
# ─────────────────────────────────────────────────────────────────────────────
ACPI_CALL_COPR    ?= rhea/acpi_call
ACPI_CALL_PKG     ?= acpi_call-dkms
ACPI_CALL_GIT_URL ?= https://github.com/nix-community/acpi_call.git

# ─────────────────────────────────────────────────────────────────────────────
# Distro / hardware detection
# ─────────────────────────────────────────────────────────────────────────────
DMI_VENDOR      := $(shell cat /sys/class/dmi/id/chassis_vendor 2>/dev/null)
DMI_PRODUCT     := $(shell cat /sys/class/dmi/id/product_name 2>/dev/null)
# In distrobox read the HOST os-release so VARIANT_ID=silverblue, not "container"
_OS_RELEASE     := $(if $(filter yes,$(IS_DISTROBOX)),/run/host/etc/os-release,/etc/os-release)
OS_ID           := $(shell . $(_OS_RELEASE) 2>/dev/null && echo $$ID)
OS_VARIANT      := $(shell . $(_OS_RELEASE) 2>/dev/null && echo $$VARIANT_ID)
OS_VERSION      := $(shell . $(_OS_RELEASE) 2>/dev/null && echo $$VERSION_ID)
KERNEL          := $(shell uname -r)

# Backend hints
HAS_SYSFS_END   := $(shell ls /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1)
HAS_ACPI_CALL   := $(shell test -e /proc/acpi/call && echo yes || echo no)
HAS_TPACPI_BAT  := $(shell command -v tpacpi-bat >/dev/null 2>&1 && echo yes || echo no)

VENDOR_LC       := $(shell echo "$(DMI_VENDOR)" | tr A-Z a-z)
IS_XIAOMI       := $(if $(filter xiaomi,$(VENDOR_LC)),yes,no)
IS_THINKPAD     := $(shell echo "$(DMI_PRODUCT)" | grep -qi thinkpad && echo yes || echo no)

# Colors
ifdef NO_COLOR
  C_RESET :=
  C_BOLD  :=
  C_OK    :=
  C_WARN  :=
  C_ERR   :=
  C_INFO  :=
else
  C_RESET := \033[0m
  C_BOLD  := \033[1m
  C_OK    := \033[1;32m
  C_WARN  := \033[1;33m
  C_ERR   := \033[1;31m
  C_INFO  := \033[1;36m
endif

.PHONY: all help doctor deps install-deps build daemon extension schemas generate \
        install install-system install-extension install-activate \
        _try-enable-extension enable-extension uninstall \
        reload restart test lint dist clean probe \
        daemon-dev check-root _check_installed \
        package-rpm package-deb package-tarball

all: build

# ─────────────────────────────────────────────────────────────────────────────
help:
	@printf "$(C_BOLD)Battery Threshold — Makefile targets$(C_RESET)\n\n"
	@printf "  $(C_INFO)Setup:$(C_RESET)\n"
	@printf "    make doctor              Show detected system & install status\n"
	@printf "    make deps                Check & guide installing kernel modules / repos\n"
	@printf "    make probe               Run hardware probe (scripts/probe.sh)\n\n"
	@printf "  $(C_INFO)Build:$(C_RESET)\n"
	@printf "    make build               Compile daemon + bundle extension (no root)\n"
	@printf "    make daemon              Compile just the Rust daemon\n"
	@printf "    make extension           Bundle just the GJS extension\n\n"
	@printf "  $(C_INFO)Install:$(C_RESET)\n"
	@printf "    sudo make install        Install everything (auto-picks PREFIX; prompts for deps)\n"
	@printf "    sudo make install BATTERY_THRESHOLD_AUTO_DEPS=1   Auto-install kernel deps\n"
	@printf "    sudo make install BATTERY_THRESHOLD_APPLY_LIVE=1  Try rpm-ostree --apply-live for deps\n"
	@printf "    sudo make install BATTERY_THRESHOLD_ACPI_CALL_RPM_URL=<url-to-rpm>  Use custom acpi_call RPM\n"
	@printf "    sudo make install BATTERY_THRESHOLD_NO_DEPS=1     Skip dep installation\n"
	@printf "    sudo make install NO_ACTIVATE=1   Install without starting daemon\n"
	@printf "    sudo make install-deps   Install only the vendor-specific kernel deps\n"
	@printf "    sudo make uninstall      Remove everything\n"
	@printf "    sudo make reload         daemon-reload + restart daemon\n"
	@printf "    make enable-extension    Enable GNOME extension (user, no sudo)\n\n"
	@printf "  $(C_INFO)Package:$(C_RESET)\n"
	@printf "    make dist                Build extension .zip for GNOME Extensions site\n"
	@printf "    make package-tarball     Source tarball (gnome-battery-threshold-VERSION.tar.gz)\n"
	@printf "    make package-rpm         Build .rpm (requires rpmbuild)\n"
	@printf "    make package-deb         Build .deb (requires dpkg-deb)\n\n"
	@printf "  $(C_INFO)Dev:$(C_RESET)\n"
	@printf "    make test                Run Rust tests + validate metadata\n"
	@printf "    make lint                cargo fmt --check + cargo clippy\n"
	@printf "    make daemon-dev          Run daemon in foreground\n"
	@printf "    make clean               Remove build artifacts\n\n"
	@printf "  $(C_INFO)Effective paths (PREFIX=$(PREFIX)):$(C_RESET)\n"
	@printf "    daemon            $(LIBEXECDIR)/$(DAEMON_NAME)\n"
	@printf "    systemd unit      $(SYSTEMD_DIR)/$(DAEMON_NAME).service\n"
	@printf "    dbus config       $(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf\n"
	@printf "    polkit action     $(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy\n"
	@printf "    extension         $(EXTENSION_DIR)\n"

# ─────────────────────────────────────────────────────────────────────────────
# doctor — full system status report
# ─────────────────────────────────────────────────────────────────────────────
doctor:
	@printf "$(C_BOLD)═══ Battery Threshold — System Doctor ═══$(C_RESET)\n\n"
	@printf "$(C_INFO)System:$(C_RESET)\n"
	@printf "  OS              : $(OS_ID)$(if $(OS_VARIANT), ($(OS_VARIANT))) $(KERNEL)\n"
	@printf "  Distrobox       : $(if $(filter yes,$(IS_DISTROBOX)),$(C_WARN)yes$(C_RESET) (system ops via distrobox-host-exec),no)\n"
	@printf "  /usr writable   : $(if $(filter no,$(IS_RO_USR)),$(C_OK)yes$(C_RESET),$(C_WARN)no (immutable)$(C_RESET))\n"
	@printf "  PREFIX picked   : $(C_OK)$(PREFIX)$(C_RESET)\n"
	@printf "  Target user     : $(REAL_USER) ($(REAL_HOME))\n\n"
	@printf "$(C_INFO)Hardware:$(C_RESET)\n"
	@printf "  Chassis vendor  : $(DMI_VENDOR)\n"
	@printf "  Product name    : $(DMI_PRODUCT)\n"
	@printf "  Xiaomi/Redmi    : $(if $(filter yes,$(IS_XIAOMI)),$(C_OK)yes$(C_RESET),no)\n"
	@printf "  ThinkPad        : $(if $(filter yes,$(IS_THINKPAD)),$(C_OK)yes$(C_RESET),no)\n\n"
	@printf "$(C_INFO)Backend availability:$(C_RESET)\n"
	@if [ -n "$(HAS_SYSFS_END)" ]; then \
	    printf "  sysfs charge_control_*   : $(C_OK)yes$(C_RESET) ($(HAS_SYSFS_END))\n"; \
	else \
	    printf "  sysfs charge_control_*   : no\n"; \
	fi
	@printf "  /proc/acpi/call          : $(if $(filter yes,$(HAS_ACPI_CALL)),$(C_OK)yes$(C_RESET),$(C_WARN)no — acpi_call module not loaded$(C_RESET))\n"
	@printf "  tpacpi-bat               : $(if $(filter yes,$(HAS_TPACPI_BAT)),$(C_OK)yes$(C_RESET),no)\n\n"
	@printf "$(C_INFO)Installed components:$(C_RESET)\n"
	@$(MAKE) --no-print-directory _check_installed
	@printf "\n$(C_INFO)Recommendation:$(C_RESET)\n"
	@if [ "$(IS_XIAOMI)" = "yes" ] && [ "$(HAS_ACPI_CALL)" = "no" ]; then \
	    printf "  $(C_WARN)→ Xiaomi laptop detected but acpi_call is missing.$(C_RESET)\n"; \
	    printf "    Run: $(C_BOLD)sudo make install-deps$(C_RESET) (auto) or $(C_BOLD)make deps$(C_RESET) (guide).\n"; \
	elif [ "$(IS_THINKPAD)" = "yes" ] && [ "$(HAS_ACPI_CALL)" = "no" ] && [ -z "$(HAS_SYSFS_END)" ]; then \
	    printf "  $(C_WARN)→ ThinkPad detected; consider installing acpi_call.$(C_RESET)\n"; \
	    printf "    Run: $(C_BOLD)make deps$(C_RESET)\n"; \
	elif [ -n "$(HAS_SYSFS_END)" ]; then \
	    printf "  $(C_OK)→ sysfs backend available — no kernel module needed.$(C_RESET)\n"; \
	elif [ "$(HAS_ACPI_CALL)" = "no" ]; then \
	    printf "  $(C_WARN)→ No charge-control backend detected. Try installing acpi_call:$(C_RESET)\n"; \
	    printf "    Run: $(C_BOLD)sudo make install-deps$(C_RESET) (auto) or $(C_BOLD)make deps$(C_RESET) (guide).\n"; \
	    printf "    If still unsupported afterwards, run $(C_BOLD)make probe$(C_RESET) and open an issue.\n"; \
	else \
	    printf "  $(C_OK)→ acpi_call is loaded.$(C_RESET) If the daemon still reports 'unsupported',\n"; \
	    printf "    run $(C_BOLD)make probe$(C_RESET) and open an issue at $(PROJECT_URL)\n"; \
	fi

_check_installed:
	@for f in \
	    "$(LIBEXECDIR)/$(DAEMON_NAME):daemon binary" \
	    "$(SYSTEMD_DIR)/$(DAEMON_NAME).service:systemd unit" \
	    "$(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf:dbus policy" \
	    "$(DBUS_SERVICES)/io.github.korrnals.BatteryThreshold.service:dbus activation" \
	    "$(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy:polkit action" \
	    "$(GSCHEMA_DIR)/io.github.korrnals.BatteryThreshold.gschema.xml:gsettings schema" \
	    "$(EXTENSION_DIR)/metadata.json:extension"; do \
	    path=$${f%%:*}; label=$${f##*:}; \
	    if $(HOST_EXEC) test -e "$$path" 2>/dev/null; then \
	        printf "  %-22s $(C_OK)✓$(C_RESET) %s\n" "$$label" "$$path"; \
	    else \
	        printf "  %-22s $(C_ERR)✗$(C_RESET) %s\n" "$$label" "$$path"; \
	    fi; \
	done
	@if $(HOST_EXEC) systemctl is-active --quiet $(DAEMON_NAME).service 2>/dev/null; then \
	    printf "  %-22s $(C_OK)active$(C_RESET)\n" "daemon (systemctl)"; \
	else \
	    printf "  %-22s $(C_WARN)inactive$(C_RESET)\n" "daemon (systemctl)"; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# deps — dependency check & installation guide
# ─────────────────────────────────────────────────────────────────────────────
deps:
	@printf "$(C_BOLD)═══ Dependency Check ═══$(C_RESET)\n\n"
	@if [ -n "$(HAS_SYSFS_END)" ] && [ "$(IS_XIAOMI)" != "yes" ]; then \
	    printf "$(C_OK)✓ sysfs backend is available — no extra kernel modules required.$(C_RESET)\n"; \
	    exit 0; \
	fi; \
	if [ "$(HAS_ACPI_CALL)" = "yes" ]; then \
	    printf "$(C_OK)✓ acpi_call is loaded — you're all set.$(C_RESET)\n"; \
	    exit 0; \
	fi; \
	if [ "$(IS_XIAOMI)" = "yes" ] || [ "$(IS_THINKPAD)" = "yes" ]; then \
	    printf "$(C_WARN)Missing: acpi_call kernel module$(C_RESET)\n\n"; \
	    printf "Required for Xiaomi/Redmi and some ThinkPads.\n\n"; \
	else \
	    printf "$(C_WARN)Missing: acpi_call kernel module$(C_RESET)\n\n"; \
	    printf "sysfs charge_control_* not exposed by '$(DMI_VENDOR) $(DMI_PRODUCT)'.\n"; \
	    printf "acpi_call works on many laptops (Xiaomi/Redmi, some Asus, MSI, Lenovo).\n"; \
	    printf "It is safe to try — run 'make probe' afterwards to confirm support.\n\n"; \
	fi; \
	case "$(OS_ID)" in \
	        fedora) \
	            if [ "$(OS_VARIANT)" = "silverblue" ] || [ "$(OS_VARIANT)" = "kinoite" ] || [ "$(OS_VARIANT)" = "sericea" ]; then \
	                printf "$(C_INFO)Fedora Atomic ($(OS_VARIANT)) — via rpm-ostree:$(C_RESET)\n"; \
	                printf "  1. Enable RPM Fusion (free):\n"; \
	                printf "     $(C_BOLD)sudo rpm-ostree install \\\\\n        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(OS_VERSION).noarch.rpm$(C_RESET)\n"; \
	                printf "  2. $(C_BOLD)sudo systemctl reboot$(C_RESET)\n"; \
	                printf "  3. $(C_BOLD)sudo rpm-ostree install akmod-acpi_call$(C_RESET)\n"; \
	                printf "  4. $(C_BOLD)sudo systemctl reboot$(C_RESET)\n"; \
	            else \
	                printf "$(C_INFO)Fedora — via dnf:$(C_RESET)\n"; \
	                printf "  1. RPM Fusion (free):\n"; \
	                printf "     $(C_BOLD)sudo dnf install \\\\\n        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(OS_VERSION).noarch.rpm$(C_RESET)\n"; \
	                printf "  2. $(C_BOLD)sudo dnf install akmod-acpi_call$(C_RESET)\n"; \
	                printf "  3. Reboot or: $(C_BOLD)sudo modprobe acpi_call$(C_RESET)\n"; \
	            fi ;; \
	        ubuntu|debian|linuxmint|pop) \
	            printf "$(C_INFO)Debian / Ubuntu:$(C_RESET)\n"; \
	            printf "  $(C_BOLD)sudo apt install acpi-call-dkms$(C_RESET)\n"; \
	            printf "  $(C_BOLD)sudo modprobe acpi_call$(C_RESET)\n" ;; \
	        arch|manjaro|endeavouros) \
	            printf "$(C_INFO)Arch / Manjaro:$(C_RESET)\n"; \
	            printf "  $(C_BOLD)sudo pacman -S acpi_call-dkms$(C_RESET)\n"; \
	            printf "  $(C_BOLD)sudo modprobe acpi_call$(C_RESET)\n" ;; \
	        opensuse*|suse) \
	            printf "$(C_INFO)openSUSE:$(C_RESET)\n"; \
	            printf "  $(C_BOLD)sudo zypper install acpi_call-kmp-default$(C_RESET)\n" ;; \
	        *) \
	            printf "$(C_INFO)Generic — check your distro for 'acpi_call' or 'acpi-call'.$(C_RESET)\n"; \
	            printf "  Source: https://github.com/nix-community/acpi_call\n" ;; \
	    esac; \
	    printf "\nAfter installation, verify with:\n  $(C_BOLD)test -e /proc/acpi/call && echo OK$(C_RESET)\n"

# ─────────────────────────────────────────────────────────────────────────────
# build
# ─────────────────────────────────────────────────────────────────────────────
build: daemon extension schemas generate

daemon:
	@printf "$(C_INFO)▸ Building daemon ($(DAEMON_NAME))$(C_RESET)\n"
	$(CARGO) build --release --manifest-path src/daemon/Cargo.toml

extension:
	@printf "$(C_INFO)▸ Preparing extension bundle$(C_RESET)\n"
	@mkdir -p $(BUILD_DIR)/extension/schemas $(BUILD_DIR)/extension/icons
	@cp src/extension/extension.js   $(BUILD_DIR)/extension/
	@cp src/extension/prefs.js       $(BUILD_DIR)/extension/
	@cp src/extension/metadata.json  $(BUILD_DIR)/extension/
	@cp src/extension/stylesheet.css $(BUILD_DIR)/extension/
	@cp src/extension/icons/*.svg    $(BUILD_DIR)/extension/icons/
	@cp data/schemas/*.gschema.xml   $(BUILD_DIR)/extension/schemas/
	@glib-compile-schemas $(BUILD_DIR)/extension/schemas

schemas:
	@printf "$(C_INFO)▸ Compiling GSettings schemas$(C_RESET)\n"
	@glib-compile-schemas data/schemas

# Generate systemd & D-Bus activation files with the correct LIBEXECDIR
# substituted in. Source files use the literal /usr/libexec/ path; we rewrite
# it at install time so /usr/local/libexec/ also works on immutable distros.
generate:
	@mkdir -p $(GEN_DIR)
	@sed 's|/usr/libexec/$(DAEMON_NAME)|$(LIBEXECDIR)/$(DAEMON_NAME)|g' \
	    data/systemd/$(DAEMON_NAME).service > $(GEN_DIR)/$(DAEMON_NAME).service
	@sed 's|/usr/libexec/$(DAEMON_NAME)|$(LIBEXECDIR)/$(DAEMON_NAME)|g' \
	    data/dbus/io.github.korrnals.BatteryThreshold.service \
	    > $(GEN_DIR)/io.github.korrnals.BatteryThreshold.service

# ─────────────────────────────────────────────────────────────────────────────
# install / uninstall
# ─────────────────────────────────────────────────────────────────────────────
check-root:
ifeq ($(IS_DISTROBOX),yes)
	@printf "$(C_INFO)ℹ Distrobox detected — system ops via distrobox-host-exec$(C_RESET)\n"
else
	@if [ "$$(id -u)" -ne 0 ] && [ -z "$(DESTDIR)" ]; then \
	    printf "$(C_ERR)Error:$(C_RESET) system install needs root.\n"; \
	    printf "  Run: $(C_BOLD)sudo make install$(C_RESET)\n"; \
	    exit 1; \
	fi
endif

install: install-deps build install-system install-extension install-activate _try-enable-extension
	@printf "\n$(C_OK)✓ Installation complete.$(C_RESET)\n"
	@printf "Tip: $(C_BOLD)make doctor$(C_RESET) to verify everything is in place.\n"

# ─────────────────────────────────────────────────────────────────────────────
# install-deps — auto/interactive install of vendor-specific kernel modules.
#
#   • If a backend is already available, no-op.
#   • If running on a non-interactive shell, prints what's needed and continues
#     (the daemon will simply report 'unsupported' until deps are installed).
#   • Otherwise asks the user [Y/n] before invoking the appropriate package
#     manager. Set BATTERY_THRESHOLD_AUTO_DEPS=1 to skip the prompt.
#   • Set BATTERY_THRESHOLD_NO_DEPS=1 to skip dep installation entirely.
# ─────────────────────────────────────────────────────────────────────────────
install-deps:
	@if [ -n "$$BATTERY_THRESHOLD_NO_DEPS" ]; then \
	    printf "$(C_INFO)▸ Skipping dep check (BATTERY_THRESHOLD_NO_DEPS=1)$(C_RESET)\n"; \
	    exit 0; \
	fi; \
	if [ -n "$(HAS_SYSFS_END)" ] || [ "$(HAS_ACPI_CALL)" = "yes" ]; then \
	    printf "$(C_OK)✓ Charge-control backend already available — no extra deps needed.$(C_RESET)\n"; \
	    exit 0; \
	fi; \
	if [ "$(IS_XIAOMI)" = "yes" ] || [ "$(IS_THINKPAD)" = "yes" ]; then \
	    printf "$(C_WARN)▸ acpi_call kernel module is required for $(DMI_VENDOR) hardware.$(C_RESET)\n"; \
	else \
	    printf "$(C_WARN)▸ No sysfs charge-control on '$(DMI_VENDOR) $(DMI_PRODUCT)'.$(C_RESET)\n"; \
	    printf "$(C_INFO)  Will try to install the acpi_call kernel module — it works on many laptops\n  not yet covered by sysfs. Run 'make probe' afterwards to verify support.$(C_RESET)\n"; \
	fi; \
	REPLY=y; \
	if [ -z "$$BATTERY_THRESHOLD_AUTO_DEPS" ]; then \
	    if [ -t 0 ] && [ -t 1 ]; then \
	        printf "  Install required dependencies now? [Y/n] "; \
	        read REPLY </dev/tty || REPLY=n; \
	    else \
	        printf "$(C_INFO)  Non-interactive shell — skipping. Re-run with BATTERY_THRESHOLD_AUTO_DEPS=1$(C_RESET)\n"; \
	        printf "$(C_INFO)  or run 'make deps' for manual instructions.$(C_RESET)\n"; \
	        exit 0; \
	    fi; \
	fi; \
	case "$$REPLY" in \
	    [Nn]*) printf "$(C_WARN)  Skipped. See 'make deps' for manual steps.$(C_RESET)\n"; exit 0;; \
	esac; \
	case "$(OS_ID)" in \
	    fedora) \
	        if [ "$(OS_VARIANT)" = "silverblue" ] || [ "$(OS_VARIANT)" = "kinoite" ] || [ "$(OS_VARIANT)" = "sericea" ]; then \
	            if [ "$(IS_DISTROBOX)" != "yes" ]; then \
	                printf "$(C_ERR)  On rpm-ostree atomic systems the acpi_call module must be built$(C_RESET)\n"; \
	                printf "$(C_ERR)  out-of-tree. Re-run 'sudo make install-deps' from inside a distrobox$(C_RESET)\n"; \
	                printf "$(C_ERR)  or toolbox container (where kernel-devel can be installed).$(C_RESET)\n"; \
	                exit 1; \
	            fi; \
	            KVER=$$($(HOST_EXEC) uname -r 2>/dev/null); \
	            [ -n "$$KVER" ] || { printf "$(C_ERR)  Could not read host kernel version.$(C_RESET)\n"; exit 1; }; \
	            printf "$(C_INFO)▸ Atomic Fedora — building acpi_call.ko out-of-tree for kernel %s$(C_RESET)\n" "$$KVER"; \
	            WORKDIR=$$(mktemp -d); \
	            trap "rm -rf $$WORKDIR" EXIT; \
	            printf "$(C_INFO)  ▸ Installing build deps in container$(C_RESET)\n"; \
	            if ! sudo dnf install -y --setopt=install_weak_deps=False \
	                kernel-devel-$$KVER gcc make git rpm-build 2>&1; then \
	                K_ARCH=$${KVER##*.}; \
	                K_VR=$${KVER%.*}; \
	                K_VER=$${K_VR%-*}; \
	                K_REL=$${K_VR#*-}; \
	                KOJI_URL="https://kojipkgs.fedoraproject.org/packages/kernel/$$K_VER/$$K_REL/$$K_ARCH/kernel-devel-$$K_VER-$$K_REL.$$K_ARCH.rpm"; \
	                printf "$(C_WARN)  kernel-devel-$$KVER not in repos; trying Koji archive$(C_RESET)\n"; \
	                printf "$(C_INFO)  ▸ %s$(C_RESET)\n" "$$KOJI_URL"; \
	                sudo dnf install -y --setopt=install_weak_deps=False \
	                    "$$KOJI_URL" gcc make git rpm-build \
	                    || { printf "$(C_ERR)  Failed to install kernel-devel from Koji.$(C_RESET)\n"; \
	                         printf "$(C_ERR)  Host kernel: %s$(C_RESET)\n" "$$KVER"; \
	                         exit 1; }; \
	            fi; \
	            printf "$(C_INFO)  ▸ Cloning %s$(C_RESET)\n" "$(ACPI_CALL_GIT_URL)"; \
	            git clone --depth 1 "$(ACPI_CALL_GIT_URL)" "$$WORKDIR/src" \
	                || { printf "$(C_ERR)  git clone failed.$(C_RESET)\n"; exit 1; }; \
	            printf "$(C_INFO)  ▸ Compiling acpi_call.ko$(C_RESET)\n"; \
	            make -C /usr/src/kernels/$$KVER M="$$WORKDIR/src" modules \
	                || { printf "$(C_ERR)  Module build failed.$(C_RESET)\n"; exit 1; }; \
	            [ -f "$$WORKDIR/src/acpi_call.ko" ] \
	                || { printf "$(C_ERR)  acpi_call.ko not produced.$(C_RESET)\n"; exit 1; }; \
	            printf "$(C_INFO)  ▸ Packaging acpi_call-kmod-%s rpm$(C_RESET)\n" "$$KVER"; \
	            mkdir -p "$$WORKDIR/rpmbuild"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}; \
	            cp "$$WORKDIR/src/acpi_call.ko" "$$WORKDIR/rpmbuild/SOURCES/acpi_call.ko"; \
	            rpmbuild --define "_topdir $$WORKDIR/rpmbuild" \
	                     --define "kver $$KVER" \
	                     -bb data/rpm/acpi_call-kmod.spec \
	                || { printf "$(C_ERR)  rpmbuild failed.$(C_RESET)\n"; exit 1; }; \
	            RPM_FILE=$$(find "$$WORKDIR/rpmbuild/RPMS" -type f -name '*.rpm' | head -1); \
	            [ -n "$$RPM_FILE" ] \
	                || { printf "$(C_ERR)  No RPM produced.$(C_RESET)\n"; exit 1; }; \
	            HOST_RPM="$(REAL_HOME)/.cache/acpi_call-kmod-$$KVER.rpm"; \
	            mkdir -p "$(REAL_HOME)/.cache"; \
	            cp "$$RPM_FILE" "$$HOST_RPM" \
	                || { printf "$(C_ERR)  Could not stage RPM to %s$(C_RESET)\n" "$$HOST_RPM"; exit 1; }; \
	            printf "$(C_INFO)  ▸ Loading acpi_call into running kernel (insmod)$(C_RESET)\n"; \
	            $(HSUDO) insmod "$$WORKDIR/src/acpi_call.ko" 2>/dev/null \
	                || $(HSUDO) sh -c "lsmod | grep -q '^acpi_call'" \
	                || printf "$(C_WARN)  insmod failed — Secure Boot may block unsigned modules.$(C_RESET)\n"; \
	            $(HSUDO) sh -c 'echo acpi_call > /etc/modules-load.d/acpi_call.conf' \
	                || printf "$(C_WARN)  Could not persist /etc/modules-load.d/acpi_call.conf$(C_RESET)\n"; \
	            printf "$(C_INFO)  ▸ Layering RPM via rpm-ostree (persists across reboots)$(C_RESET)\n"; \
	            if $(HSUDO) rpm-ostree install --idempotent --assumeyes "$$HOST_RPM" 2>&1; then \
	                printf "$(C_OK)✓ acpi_call layered; will be available after reboot.$(C_RESET)\n"; \
	            else \
	                printf "$(C_WARN)  rpm-ostree install failed (module is still loaded for current boot).$(C_RESET)\n"; \
	                printf "$(C_WARN)  RPM kept at %s — install manually with: sudo rpm-ostree install %s$(C_RESET)\n" "$$HOST_RPM" "$$HOST_RPM"; \
	            fi; \
	            if $(HSUDO) sh -c "lsmod | grep -q '^acpi_call'"; then \
	                printf "$(C_OK)✓ acpi_call active in running kernel ($$KVER).$(C_RESET)\n"; \
	            fi; \
	        else \
	            COPR_REPO=$${BATTERY_THRESHOLD_ACPI_CALL_COPR:-$(ACPI_CALL_COPR)}; \
	            printf "$(C_INFO)▸ Fedora — enabling COPR %s and installing %s via dnf$(C_RESET)\n" "$$COPR_REPO" "$(ACPI_CALL_PKG)"; \
	            $(HSUDO) dnf install -y dnf-plugins-core || true; \
	            $(HSUDO) dnf copr enable -y "$$COPR_REPO" || \
	                { printf "$(C_ERR)  Failed to enable COPR repo $$COPR_REPO.$(C_RESET)\n"; exit 1; }; \
	            $(HSUDO) dnf install -y $(ACPI_CALL_PKG) kernel-devel dkms || \
	                { printf "$(C_ERR)  Package install failed. See 'make deps'.$(C_RESET)\n"; exit 1; }; \
	            $(HSUDO) modprobe acpi_call 2>/dev/null || \
	                printf "$(C_WARN)  Module not loadable yet — reboot may be required.$(C_RESET)\n"; \
	        fi ;; \
	    ubuntu|debian|linuxmint|pop) \
	        printf "$(C_INFO)▸ Debian/Ubuntu — installing acpi-call-dkms$(C_RESET)\n"; \
	        $(HSUDO) apt-get update && $(HSUDO) apt-get install -y acpi-call-dkms || \
	            { printf "$(C_ERR)  Package install failed.$(C_RESET)\n"; exit 1; }; \
	        $(HSUDO) modprobe acpi_call 2>/dev/null || true ;; \
	    arch|manjaro|endeavouros) \
	        printf "$(C_INFO)▸ Arch — installing acpi_call-dkms$(C_RESET)\n"; \
	        $(HSUDO) pacman -S --noconfirm acpi_call-dkms || \
	            { printf "$(C_ERR)  Package install failed.$(C_RESET)\n"; exit 1; }; \
	        $(HSUDO) modprobe acpi_call 2>/dev/null || true ;; \
	    opensuse*|suse) \
	        printf "$(C_INFO)▸ openSUSE — installing acpi_call-kmp-default$(C_RESET)\n"; \
	        $(HSUDO) zypper install -y acpi_call-kmp-default || \
	            { printf "$(C_ERR)  Package install failed.$(C_RESET)\n"; exit 1; } ;; \
	    *) \
	        printf "$(C_WARN)  Unknown distro '$(OS_ID)' — see 'make deps' for manual steps.$(C_RESET)\n" ;; \
	esac

# Activates the systemd unit unless NO_ACTIVATE=1 is set.
install-activate: check-root
ifndef NO_ACTIVATE
	@printf "$(C_INFO)▸ Reloading systemd & enabling daemon$(C_RESET)\n"
	@$(HSUDO) systemctl daemon-reload
	@$(HSUDO) systemctl enable --now $(DAEMON_NAME).service || \
	    printf "$(C_WARN)  daemon failed to start — run 'journalctl -u $(DAEMON_NAME)' to investigate.$(C_RESET)\n"
else
	@printf "$(C_INFO)▸ Skipping daemon activation (NO_ACTIVATE=1)$(C_RESET)\n"
endif


install-system: check-root generate
	@printf "$(C_INFO)▸ Installing daemon → $(LIBEXECDIR)$(C_RESET)\n"
	$(HSUDO) install -Dm755 src/daemon/target/release/$(DAEMON_NAME) \
	    $(DESTDIR)$(LIBEXECDIR)/$(DAEMON_NAME)
	@printf "$(C_INFO)▸ Installing systemd unit → $(SYSTEMD_DIR)$(C_RESET)\n"
	$(HSUDO) install -Dm644 $(GEN_DIR)/$(DAEMON_NAME).service \
	    $(DESTDIR)$(SYSTEMD_DIR)/$(DAEMON_NAME).service
	@printf "$(C_INFO)▸ Installing D-Bus policy → $(DBUS_SYSTEM_DIR)$(C_RESET)\n"
	$(HSUDO) install -Dm644 data/dbus/io.github.korrnals.BatteryThreshold.conf \
	    $(DESTDIR)$(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf
	@printf "$(C_INFO)▸ Installing D-Bus activation → $(DBUS_SERVICES)$(C_RESET)\n"
	$(HSUDO) install -Dm644 $(GEN_DIR)/io.github.korrnals.BatteryThreshold.service \
	    $(DESTDIR)$(DBUS_SERVICES)/io.github.korrnals.BatteryThreshold.service
	@printf "$(C_INFO)▸ Installing PolicyKit action → $(POLKIT_DIR)$(C_RESET)\n"
	$(HSUDO) install -Dm644 data/policy/io.github.korrnals.BatteryThreshold.policy \
	    $(DESTDIR)$(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy
	@printf "$(C_INFO)▸ Installing GSettings schema → $(GSCHEMA_DIR)$(C_RESET)\n"
	$(HSUDO) install -Dm644 data/schemas/io.github.korrnals.BatteryThreshold.gschema.xml \
	    $(DESTDIR)$(GSCHEMA_DIR)/io.github.korrnals.BatteryThreshold.gschema.xml
	$(HSUDO) glib-compile-schemas $(DESTDIR)$(GSCHEMA_DIR)

install-extension: extension
	@printf "$(C_INFO)▸ Installing GNOME extension → $(EXTENSION_DIR)$(C_RESET)\n"
	@$(HOST_EXEC) mkdir -p "$(EXTENSION_DIR)"
	@$(HOST_EXEC) cp -r $(BUILD_DIR)/extension/* "$(EXTENSION_DIR)/"
	@if [ -n "$(SUDO_USER)" ] && [ -d "$(EXTENSION_DIR)" ]; then \
	    $(HSUDO) chown -R $(SUDO_USER): "$(EXTENSION_DIR)"; \
	fi

uninstall: check-root
	@printf "$(C_INFO)▸ Stopping daemon$(C_RESET)\n"
	-$(HSUDO) systemctl disable --now $(DAEMON_NAME).service 2>/dev/null || true
	@printf "$(C_INFO)▸ Removing system files$(C_RESET)\n"
	$(HSUDO) rm -f $(DESTDIR)$(LIBEXECDIR)/$(DAEMON_NAME)
	$(HSUDO) rm -f $(DESTDIR)$(SYSTEMD_DIR)/$(DAEMON_NAME).service
	$(HSUDO) rm -f $(DESTDIR)$(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf
	$(HSUDO) rm -f $(DESTDIR)$(DBUS_SERVICES)/io.github.korrnals.BatteryThreshold.service
	$(HSUDO) rm -f $(DESTDIR)$(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy
	$(HSUDO) rm -f $(DESTDIR)$(GSCHEMA_DIR)/io.github.korrnals.BatteryThreshold.gschema.xml
	-$(HSUDO) glib-compile-schemas $(DESTDIR)$(GSCHEMA_DIR) 2>/dev/null || true
	@printf "$(C_INFO)▸ Removing extension$(C_RESET)\n"
	$(HOST_EXEC) rm -rf "$(EXTENSION_DIR)"
	-$(HSUDO) systemctl daemon-reload 2>/dev/null || true
	@printf "$(C_OK)✓ Uninstalled.$(C_RESET) State dir /var/lib/$(DAEMON_NAME) preserved.\n"

# ─────────────────────────────────────────────────────────────────────────────
# convenience
# ─────────────────────────────────────────────────────────────────────────────
reload: check-root
	$(HSUDO) systemctl daemon-reload
	$(HSUDO) systemctl restart $(DAEMON_NAME).service
	@printf "$(C_OK)✓ Daemon reloaded.$(C_RESET)\n"
	@$(HSUDO) systemctl status $(DAEMON_NAME).service --no-pager -l | head -15

restart: reload

enable-extension:
	@_uid="$(HOST_UID)"; \
	 _uuid="$(UUID)"; \
	 _run="/run/user/$$_uid"; \
	 printf "$(C_INFO)▸ Enabling GNOME extension$(C_RESET)\n"; \
	 if $(HOST_EXEC) env \
	         XDG_RUNTIME_DIR="$$_run" \
	         DBUS_SESSION_BUS_ADDRESS="unix:path=$$_run/bus" \
	         gnome-extensions enable "$$_uuid" 2>&1; then \
	     printf "$(C_OK)✓ Extension enabled.$(C_RESET)\n"; \
	 else \
	     printf "$(C_WARN)⚠ Enable failed — if recently installed, log out & back in first, then retry.$(C_RESET)\n"; \
	 fi

# Internal: called by 'install'. Tries to enable the extension immediately via
# D-Bus; if GNOME Shell has not scanned it yet (first install on Wayland) falls
# back to pre-registering it in the GSettings enabled-extensions list so it
# activates automatically on the next login.
_try-enable-extension:
	@_uid="$(HOST_UID)"; \
	 _uuid="$(UUID)"; \
	 _run="/run/user/$$_uid"; \
	 printf "$(C_INFO)▸ Enabling GNOME extension$(C_RESET)\n"; \
	 if $(HOST_EXEC) env \
	         XDG_RUNTIME_DIR="$$_run" \
	         DBUS_SESSION_BUS_ADDRESS="unix:path=$$_run/bus" \
	         gnome-extensions enable "$$_uuid" 2>/dev/null; then \
	     printf "$(C_OK)  ✓ Extension enabled$(C_RESET)\n"; \
	 else \
	     printf "$(C_INFO)  ℹ GNOME Shell hasn't scanned it yet — pre-registering in GSettings...$(C_RESET)\n"; \
	     _cur=$$($(HOST_EXEC) env \
	             XDG_RUNTIME_DIR="$$_run" \
	             DBUS_SESSION_BUS_ADDRESS="unix:path=$$_run/bus" \
	             gsettings get org.gnome.shell enabled-extensions 2>/dev/null \
	             || echo "@as []"); \
	     if printf '%s' "$$_cur" | grep -qF "$$_uuid"; then \
	         printf "$(C_INFO)  ℹ Already in enabled-extensions list$(C_RESET)\n"; \
	     elif printf '%s' "$$_cur" | grep -q "@as \[\]"; then \
	         if $(HOST_EXEC) env \
	                 XDG_RUNTIME_DIR="$$_run" \
	                 DBUS_SESSION_BUS_ADDRESS="unix:path=$$_run/bus" \
	                 gsettings set org.gnome.shell enabled-extensions "['$$_uuid']"; then \
	             printf "$(C_OK)  ✓ Pre-registered — extension will activate after next login$(C_RESET)\n"; \
	         else \
	             printf "$(C_WARN)  ⚠ Could not pre-register. After next login run: make enable-extension$(C_RESET)\n"; \
	         fi; \
	     else \
	         _new=$$(printf '%s' "$$_cur" | sed "s/]$$/, '$$_uuid']/"); \
	         if $(HOST_EXEC) env \
	                 XDG_RUNTIME_DIR="$$_run" \
	                 DBUS_SESSION_BUS_ADDRESS="unix:path=$$_run/bus" \
	                 gsettings set org.gnome.shell enabled-extensions "$$_new"; then \
	             printf "$(C_OK)  ✓ Pre-registered — extension will activate after next login$(C_RESET)\n"; \
	         else \
	             printf "$(C_WARN)  ⚠ Could not pre-register. After next login run: make enable-extension$(C_RESET)\n"; \
	         fi; \
	     fi; \
	 fi

probe:
	@bash scripts/probe.sh

daemon-dev:
	@printf "$(C_INFO)▸ Running daemon in foreground (requires root for hardware access)$(C_RESET)\n"
	$(CARGO) run --manifest-path src/daemon/Cargo.toml

# ─────────────────────────────────────────────────────────────────────────────
# test / lint / dist / clean
# ─────────────────────────────────────────────────────────────────────────────
test:
	@printf "$(C_INFO)▸ Running Rust tests$(C_RESET)\n"
	$(CARGO) test --manifest-path src/daemon/Cargo.toml
	@printf "$(C_INFO)▸ Validating extension metadata.json$(C_RESET)\n"
	@if command -v jq >/dev/null 2>&1; then \
	    jq -e . src/extension/metadata.json >/dev/null && printf "  $(C_OK)✓ metadata.json valid$(C_RESET)\n"; \
	elif command -v python3 >/dev/null 2>&1; then \
	    python3 -c "import json; json.load(open('src/extension/metadata.json'))" && printf "  $(C_OK)✓ metadata.json valid$(C_RESET)\n"; \
	else \
	    printf "  $(C_WARN)skipped (neither jq nor python3 available)$(C_RESET)\n"; \
	fi

lint:
	@printf "$(C_INFO)▸ cargo fmt --check$(C_RESET)\n"
	$(CARGO) fmt --manifest-path src/daemon/Cargo.toml -- --check
	@printf "$(C_INFO)▸ cargo clippy$(C_RESET)\n"
	$(CARGO) clippy --manifest-path src/daemon/Cargo.toml --all-targets -- -D warnings

dist: extension
	@printf "$(C_INFO)▸ Creating extension zip$(C_RESET)\n"
	@mkdir -p dist
	cd $(BUILD_DIR)/extension && zip -r ../../dist/$(UUID)-v$(VERSION).zip .
	@printf "$(C_OK)✓ dist/$(UUID)-v$(VERSION).zip$(C_RESET)\n"

clean:
	rm -rf $(BUILD_DIR) dist
	$(CARGO) clean --manifest-path src/daemon/Cargo.toml 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# packaging — .tar.gz / .rpm / .deb
# ─────────────────────────────────────────────────────────────────────────────
PKG_NAME    := gnome-battery-threshold
PKG_VERSION := $(VERSION)
TARBALL     := dist/$(PKG_NAME)-$(PKG_VERSION).tar.gz

package-tarball:
	@printf "$(C_INFO)▸ Creating source tarball$(C_RESET)\n"
	@mkdir -p dist
	@mkdir -p $(BUILD_DIR)
	@git ls-files 2>/dev/null > $(BUILD_DIR)/.tarball-files || \
	    find . -type f \! -path './target/*' \! -path './dist/*' \! -path './.git/*' \
	        \! -path './src/daemon/target/*' | sed 's|^\./||' > $(BUILD_DIR)/.tarball-files
	@tar --transform 's,^,$(PKG_NAME)-$(PKG_VERSION)/,' \
	    -czf $(TARBALL) -T $(BUILD_DIR)/.tarball-files
	@printf "$(C_OK)✓ $(TARBALL)$(C_RESET)\n"

package-rpm: package-tarball
	@command -v rpmbuild >/dev/null 2>&1 || { \
	    printf "$(C_ERR)rpmbuild not found.$(C_RESET) Install: $(C_BOLD)sudo dnf install rpm-build$(C_RESET) (or rpm on Silverblue toolbox).\n"; \
	    exit 1; \
	}
	@printf "$(C_INFO)▸ Building RPM$(C_RESET)\n"
	@mkdir -p $(BUILD_DIR)/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@cp $(TARBALL) $(BUILD_DIR)/rpmbuild/SOURCES/
	@$(MAKE) --no-print-directory _gen_rpm_spec > $(BUILD_DIR)/rpmbuild/SPECS/$(PKG_NAME).spec
	@rpmbuild --define "_topdir $(CURDIR)/$(BUILD_DIR)/rpmbuild" \
	    -bb $(BUILD_DIR)/rpmbuild/SPECS/$(PKG_NAME).spec
	@mkdir -p dist
	@cp $(BUILD_DIR)/rpmbuild/RPMS/*/*.rpm dist/
	@printf "$(C_OK)✓ dist/$(PKG_NAME)-$(PKG_VERSION)*.rpm$(C_RESET)\n"

_gen_rpm_spec:
	@echo 'Name:           $(PKG_NAME)'
	@echo 'Version:        $(PKG_VERSION)'
	@echo 'Release:        1%{?dist}'
	@echo 'Summary:        GNOME Shell extension to control laptop battery charge thresholds'
	@echo 'License:        GPL-3.0-or-later'
	@echo 'URL:            $(PROJECT_URL)'
	@echo 'Source0:        %{name}-%{version}.tar.gz'
	@echo 'BuildRequires:  cargo rust glib2-devel systemd-rpm-macros'
	@echo 'Requires:       glib2 dbus polkit systemd'
	@echo 'Recommends:     gnome-shell'
	@echo ''
	@echo '%global debug_package %{nil}'
	@echo '%global __strip /bin/true'
	@echo ''
	@echo '%description'
	@echo 'A GNOME Shell extension that limits laptop battery maximum charge'
	@echo 'level to prolong battery life. Includes a privileged Rust daemon'
	@echo 'communicating via D-Bus and PolicyKit, with backends for standard'
	@echo 'sysfs, Xiaomi/Redmi (acpi_call), and ThinkPad.'
	@echo ''
	@echo '%prep'
	@echo '%autosetup'
	@echo ''
	@echo '%build'
	@echo 'make build CARGO_BUILD_FLAGS=--offline || make build'
	@echo ''
	@echo '%install'
	@echo 'make install-system DESTDIR=%{buildroot} PREFIX=/usr SYSCONFDIR=/etc HSUDO='
	@echo 'mkdir -p %{buildroot}/usr/share/gnome-shell/extensions/$(UUID)'
	@echo 'cp -r target/extension/* %{buildroot}/usr/share/gnome-shell/extensions/$(UUID)/'
	@echo ''
	@echo '%files'
	@echo '%license LICENSE'
	@echo '%doc README.md CHANGELOG.md'
	@echo '/usr/libexec/$(DAEMON_NAME)'
	@echo '/etc/systemd/system/$(DAEMON_NAME).service'
	@echo '/etc/dbus-1/system.d/io.github.korrnals.BatteryThreshold.conf'
	@echo '/usr/share/dbus-1/system-services/io.github.korrnals.BatteryThreshold.service'
	@echo '/usr/share/polkit-1/actions/io.github.korrnals.BatteryThreshold.policy'
	@echo '/usr/share/glib-2.0/schemas/io.github.korrnals.BatteryThreshold.gschema.xml'
	@echo '/usr/share/gnome-shell/extensions/$(UUID)/'
	@echo ''
	@echo '%post'
	@echo '%systemd_post $(DAEMON_NAME).service'
	@echo 'glib-compile-schemas /usr/share/glib-2.0/schemas/ &>/dev/null || :'
	@echo ''
	@echo '%preun'
	@echo '%systemd_preun $(DAEMON_NAME).service'
	@echo ''
	@echo '%postun'
	@echo '%systemd_postun_with_restart $(DAEMON_NAME).service'
	@echo 'glib-compile-schemas /usr/share/glib-2.0/schemas/ &>/dev/null || :'
	@echo ''
	@echo '%changelog'
	@echo '* $(shell LC_ALL=C date "+%a %b %d %Y") Korrnals <korrnals@gmail.com> - $(PKG_VERSION)-1'
	@echo '- Release $(PKG_VERSION)'

package-deb: build
	@command -v dpkg-deb >/dev/null 2>&1 || { \
	    printf "$(C_ERR)dpkg-deb not found.$(C_RESET) Install: $(C_BOLD)sudo apt install dpkg-dev$(C_RESET)\n"; \
	    exit 1; \
	}
	@printf "$(C_INFO)▸ Building Debian package$(C_RESET)\n"
	@rm -rf $(BUILD_DIR)/deb
	@$(MAKE) --no-print-directory install-system install-extension \
	    DESTDIR=$(CURDIR)/$(BUILD_DIR)/deb \
	    PREFIX=/usr SYSCONFDIR=/etc \
	    REAL_HOME=/usr/share \
	    EXTENSION_DIR=/usr/share/gnome-shell/extensions/$(UUID) \
	    HSUDO= \
	    NO_ACTIVATE=1
	@mkdir -p $(BUILD_DIR)/deb/DEBIAN
	@{ \
	    echo 'Package: $(PKG_NAME)'; \
	    echo 'Version: $(PKG_VERSION)'; \
	    echo 'Section: gnome'; \
	    echo 'Priority: optional'; \
	    echo 'Architecture: $(shell dpkg --print-architecture 2>/dev/null || echo amd64)'; \
	    echo 'Depends: libc6, libglib2.0-0, dbus, policykit-1 | polkitd, systemd, gnome-shell'; \
	    echo 'Recommends: acpi-call-dkms'; \
	    echo 'Maintainer: Korrnals <korrnals@gmail.com>'; \
	    echo 'Homepage: $(PROJECT_URL)'; \
	    echo 'Description: GNOME Shell extension to control laptop battery charge thresholds'; \
	    echo ' Limits laptop battery maximum charge level to prolong battery life.'; \
	    echo ' Includes a privileged Rust daemon communicating via D-Bus and PolicyKit,'; \
	    echo ' with backends for sysfs, Xiaomi/Redmi (acpi_call), and ThinkPad.'; \
	} > $(BUILD_DIR)/deb/DEBIAN/control
	@printf '#!/bin/sh\nset -e\nglib-compile-schemas /usr/share/glib-2.0/schemas/ || true\nsystemctl daemon-reload || true\n' \
	    > $(BUILD_DIR)/deb/DEBIAN/postinst
	@printf '#!/bin/sh\nset -e\nsystemctl stop $(DAEMON_NAME).service 2>/dev/null || true\n' \
	    > $(BUILD_DIR)/deb/DEBIAN/prerm
	@chmod 755 $(BUILD_DIR)/deb/DEBIAN/postinst $(BUILD_DIR)/deb/DEBIAN/prerm
	@mkdir -p dist
	@dpkg-deb --build --root-owner-group $(BUILD_DIR)/deb \
	    dist/$(PKG_NAME)_$(PKG_VERSION)_$(shell dpkg --print-architecture 2>/dev/null || echo amd64).deb
	@printf "$(C_OK)✓ dist/$(PKG_NAME)_$(PKG_VERSION)_*.deb$(C_RESET)\n"

# Battery Threshold — top-level Makefile
#
# Targets:
#   build         Compile daemon + bundle extension
#   install       Install daemon, extension, schemas, polkit, systemd, dbus
#   uninstall     Remove all installed files
#   test          Run Rust unit tests + extension lint
#   lint          Format check + clippy
#   dist          Create a release zip of the extension only
#   clean         Remove build artifacts

UUID            := battery-threshold@korrnals.github.io
DAEMON_NAME     := battery-thresholdd
VERSION         := $(shell awk '/^version/{gsub(/"/,""); print $$3; exit}' src/daemon/Cargo.toml)

PREFIX          ?= /usr
LIBEXECDIR      := $(PREFIX)/libexec
DATADIR         := $(PREFIX)/share
SYSCONFDIR      ?= /etc
DBUS_SYSTEM_DIR := $(DATADIR)/dbus-1/system.d
DBUS_SERVICES   := $(DATADIR)/dbus-1/system-services
POLKIT_DIR      := $(DATADIR)/polkit-1/actions
SYSTEMD_DIR     := $(PREFIX)/lib/systemd/system
GSCHEMA_DIR     := $(DATADIR)/glib-2.0/schemas
EXTENSION_DIR   := $(DATADIR)/gnome-shell/extensions/$(UUID)

CARGO           ?= cargo
BUILD_DIR       := target

.PHONY: all build daemon extension schemas install uninstall test lint dist clean help

all: build

help:
	@echo "Battery Threshold — make targets:"
	@echo "  build       Compile daemon and prepare extension bundle"
	@echo "  install     Install everything system-wide (requires root)"
	@echo "  uninstall   Remove installed files"
	@echo "  test        Run Rust tests and lint extension"
	@echo "  lint        cargo fmt --check + cargo clippy"
	@echo "  dist        Build a distributable .zip of the extension"
	@echo "  clean       Remove build artifacts"

build: daemon extension schemas

daemon:
	@echo "▸ Building daemon ($(DAEMON_NAME))"
	$(CARGO) build --release --manifest-path src/daemon/Cargo.toml

extension:
	@echo "▸ Preparing extension bundle"
	@mkdir -p $(BUILD_DIR)/extension
	@cp src/extension/extension.js  $(BUILD_DIR)/extension/
	@cp src/extension/prefs.js      $(BUILD_DIR)/extension/
	@cp src/extension/metadata.json $(BUILD_DIR)/extension/
	@cp src/extension/stylesheet.css $(BUILD_DIR)/extension/
	@mkdir -p $(BUILD_DIR)/extension/schemas
	@cp data/schemas/*.gschema.xml  $(BUILD_DIR)/extension/schemas/
	@glib-compile-schemas $(BUILD_DIR)/extension/schemas

schemas:
	@echo "▸ Compiling GSettings schemas"
	@glib-compile-schemas data/schemas

install: build
	@echo "▸ Installing daemon to $(LIBEXECDIR)"
	install -Dm755 src/daemon/target/release/$(DAEMON_NAME) $(DESTDIR)$(LIBEXECDIR)/$(DAEMON_NAME)
	@echo "▸ Installing D-Bus config"
	install -Dm644 data/dbus/io.github.korrnals.BatteryThreshold.conf $(DESTDIR)$(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf
	install -Dm644 data/dbus/io.github.korrnals.BatteryThreshold.service $(DESTDIR)$(DBUS_SERVICES)/io.github.korrnals.BatteryThreshold.service
	@echo "▸ Installing PolicyKit action"
	install -Dm644 data/policy/io.github.korrnals.BatteryThreshold.policy $(DESTDIR)$(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy
	@echo "▸ Installing systemd unit"
	install -Dm644 data/systemd/$(DAEMON_NAME).service $(DESTDIR)$(SYSTEMD_DIR)/$(DAEMON_NAME).service
	@echo "▸ Installing GSettings schema"
	install -Dm644 data/schemas/io.github.korrnals.BatteryThreshold.gschema.xml $(DESTDIR)$(GSCHEMA_DIR)/io.github.korrnals.BatteryThreshold.gschema.xml
	glib-compile-schemas $(DESTDIR)$(GSCHEMA_DIR)
	@echo "▸ Installing GNOME Shell extension"
	install -d $(DESTDIR)$(EXTENSION_DIR)
	cp -r $(BUILD_DIR)/extension/* $(DESTDIR)$(EXTENSION_DIR)/
	@echo ""
	@echo "✓ Installed. To activate:"
	@echo "    sudo systemctl daemon-reload"
	@echo "    sudo systemctl enable --now $(DAEMON_NAME).service"
	@echo "    gnome-extensions enable $(UUID)"

uninstall:
	@echo "▸ Removing installed files"
	-systemctl disable --now $(DAEMON_NAME).service 2>/dev/null || true
	rm -f $(DESTDIR)$(LIBEXECDIR)/$(DAEMON_NAME)
	rm -f $(DESTDIR)$(DBUS_SYSTEM_DIR)/io.github.korrnals.BatteryThreshold.conf
	rm -f $(DESTDIR)$(DBUS_SERVICES)/io.github.korrnals.BatteryThreshold.service
	rm -f $(DESTDIR)$(POLKIT_DIR)/io.github.korrnals.BatteryThreshold.policy
	rm -f $(DESTDIR)$(SYSTEMD_DIR)/$(DAEMON_NAME).service
	rm -f $(DESTDIR)$(GSCHEMA_DIR)/io.github.korrnals.BatteryThreshold.gschema.xml
	glib-compile-schemas $(DESTDIR)$(GSCHEMA_DIR) 2>/dev/null || true
	rm -rf $(DESTDIR)$(EXTENSION_DIR)
	@echo "✓ Uninstalled."

test:
	@echo "▸ Running Rust tests"
	$(CARGO) test --manifest-path src/daemon/Cargo.toml
	@echo "▸ Validating extension metadata"
	@python3 -c "import json; json.load(open('src/extension/metadata.json'))" && echo "  metadata.json OK"

lint:
	@echo "▸ cargo fmt --check"
	$(CARGO) fmt --manifest-path src/daemon/Cargo.toml -- --check
	@echo "▸ cargo clippy"
	$(CARGO) clippy --manifest-path src/daemon/Cargo.toml --all-targets -- -D warnings

dist: extension
	@echo "▸ Creating extension zip"
	@mkdir -p dist
	cd $(BUILD_DIR)/extension && zip -r ../../dist/$(UUID)-v$(VERSION).zip .
	@echo "✓ dist/$(UUID)-v$(VERSION).zip"

daemon-dev:
	@echo "▸ Running daemon in foreground (requires root for hardware access)"
	$(CARGO) run --manifest-path src/daemon/Cargo.toml

clean:
	rm -rf $(BUILD_DIR) dist
	$(CARGO) clean --manifest-path src/daemon/Cargo.toml 2>/dev/null || true

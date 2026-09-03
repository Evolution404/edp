SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ARTIFACTS ?= $(ROOT)/artifacts
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
EDP_APP_SIGN_IDENTITY ?= EDP Project Code Signing
DRIVE_REV := $(shell git -C "$(ROOT)" rev-parse --short HEAD)
DRIVE_UI_PKG := $(ARTIFACTS)/EDP-Drive-UI-$(DRIVE_REV).pkg
DRIVE_UI_BINARY := $(ARTIFACTS)/edp-drive-ui
STUDIO_DERIVED_DATA := $(ARTIFACTS)/DerivedData/EDPStudio
STUDIO_PROJECT := $(ROOT)/Apps/Studio/native/EDPStudioNative/EDPStudioNative.xcodeproj

.PHONY: help status check build core-test drive-check drive-build drive-ui-status drive-stop drive-restart \
	drive-ui-package drive-ui-install drive-ui-deploy drive-installer drive-release-installer drive-env-status drive-clean-environment \
	drive-test-fast drive-test-identity drive-test-virtual-usb drive-test-storage-smoke drive-test-storage drive-test-ui drive-test-system drive-test-all \
	studio-generate studio-build

help:
	@echo "EDP common targets"
	@echo "  make check              Swift core tests + Drive strict check"
	@echo "  make build              Build Drive UI and Studio Release"
	@echo "  make drive-ui-deploy    Build, install and restart UI only (sudo)"
	@echo "  make drive-ui-package   Build signed UI-only update package"
	@echo "  make drive-ui-install   Install an existing UI package (sudo)"
	@echo "  make drive-ui-status    List every running Drive foreground UI"
	@echo "  make drive-stop         Close every Drive foreground UI"
	@echo "  make drive-restart      Close old UIs and start exactly one official UI"
	@echo "  make drive-installer    Build the native Drive component installer"
	@echo "  make drive-release-installer  Build + verify the certificate-backed combined release installer"
	@echo "  make drive-env-status   Read-only EDP Drive/macFUSE environment audit"
	@echo "  make drive-clean-environment  Remove EDP Drive + old Vault + macFUSE test environment"
	@echo "  make drive-test-fast    Hardware-free core/classifier regression"
	@echo "  make drive-test-storage-smoke  Sparse-image M01-M14 functional smoke (5 loops)"
	@echo "  make drive-test-storage Sparse-image M01-M14 release validation (5 loops)"
	@echo "  make drive-test-all     All hardware-free Drive regression gates"
	@echo "  make studio-generate    Regenerate the Studio Xcode project"
	@echo "  make studio-build       Build Studio Release without signing"
	@echo "  make status             Show branch and recent commits"

status:
	@git -C "$(ROOT)" status --short --branch
	@git -C "$(ROOT)" log --oneline -5

core-test:
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun swift test \
		--package-path "$(ROOT)/Packages/EDPCore" -c release

drive-check:
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun swiftc \
		-typecheck -swift-version 6 -warnings-as-errors \
		-framework AppKit -framework FSKit -framework SwiftUI -framework ServiceManagement \
		"$(ROOT)/Shared/UI/EDPDesignSystem.swift" \
		"$(ROOT)/Apps/Drive/product/EDPXPCProtocol.swift" \
		"$(ROOT)/Apps/Drive/product/App/EDPUSBVaultApp.swift" \
		"$(ROOT)/Apps/Drive/product/App/Service/EDPAppServiceSupport.swift" \
		"$(ROOT)/Apps/Drive/product/App/Service/EDPXPCSmokeSupport.swift" \
		"$(ROOT)/Apps/Drive/product/App/Model/EDPVaultViewModel.swift" \
		"$(ROOT)/Apps/Drive/product/App/Sidebar/EDPSidebarView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Shell/EDPMainWindow.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPOverviewView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPDevicesView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPActivityView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPSettingsView.swift" \
		"$(ROOT)/Apps/Drive/product/App/MenuBar/EDPMenuBarView.swift"

check: core-test drive-check

drive-test-fast: core-test drive-check
	@"$(ROOT)/Apps/Drive/Tests/run-fast.sh"
	@"$(ROOT)/Apps/Drive/Tests/run-block-publisher.sh"

# Canonical phase targets. Later regression phases replace these aliases with
# their dedicated harnesses while preserving a stable developer-facing API.
drive-test-identity: drive-test-fast

drive-test-virtual-usb:
	@"$(ROOT)/Apps/Drive/Tests/run-virtual-usb.sh"

drive-test-storage-smoke:
	@EDP_STORAGE_PROFILE=smoke EDP_STORAGE_LOOP_COUNT=5 "$(ROOT)/Apps/Drive/Tests/run-storage.sh"

drive-test-storage:
	@EDP_STORAGE_PROFILE=release EDP_STORAGE_LOOP_COUNT=5 "$(ROOT)/Apps/Drive/Tests/run-storage.sh"

drive-test-ui:
	@"$(ROOT)/Apps/Drive/Tests/run-ui.sh"

drive-test-system:
	@"$(ROOT)/Apps/Drive/Tests/run-system.sh"

drive-test-all: drive-test-fast drive-test-virtual-usb drive-test-storage drive-test-ui drive-test-system

drive-build:
	@mkdir -p "$(ARTIFACTS)"
	@/usr/bin/cc -O2 -Wall -Wextra -I"$(ROOT)/Apps/Drive/product" -c \
		"$(ROOT)/Apps/Drive/product/EDPRawValidation.c" -o "$(ARTIFACTS)/EDPRawValidation.o"
	@/usr/bin/cc -O2 -Wall -Wextra -I"$(ROOT)/Apps/Drive/product" -c \
		"$(ROOT)/Apps/Drive/product/EDPRawFDBroker.c" -o "$(ARTIFACTS)/EDPRawFDBroker.o"
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun swiftc \
		-O -swift-version 6 -warnings-as-errors \
		-framework AppKit -framework FSKit -framework SwiftUI -framework ServiceManagement \
		-framework CoreFoundation -framework IOKit \
		"$(ROOT)/Shared/UI/EDPDesignSystem.swift" \
		"$(ROOT)/Apps/Drive/product/EDPXPCProtocol.swift" \
		"$(ROOT)/Apps/Drive/product/App/EDPUSBVaultApp.swift" \
		"$(ROOT)/Apps/Drive/product/App/Service/EDPAppServiceSupport.swift" \
		"$(ROOT)/Apps/Drive/product/App/Service/EDPXPCSmokeSupport.swift" \
		"$(ROOT)/Apps/Drive/product/App/Model/EDPVaultViewModel.swift" \
		"$(ROOT)/Apps/Drive/product/App/Sidebar/EDPSidebarView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Shell/EDPMainWindow.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPOverviewView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPDevicesView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPActivityView.swift" \
		"$(ROOT)/Apps/Drive/product/App/Pages/EDPSettingsView.swift" \
		"$(ROOT)/Apps/Drive/product/App/MenuBar/EDPMenuBarView.swift" \
		"$(ARTIFACTS)/EDPRawValidation.o" "$(ARTIFACTS)/EDPRawFDBroker.o" \
		-o "$(DRIVE_UI_BINARY)"
	@echo "OUTPUT=$(DRIVE_UI_BINARY)"

drive-ui-package:
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" \
		EDP_APP_SIGN_IDENTITY="$(EDP_APP_SIGN_IDENTITY)" \
		"$(ROOT)/Tools/build-drive-ui-update.sh" "$(ARTIFACTS)"

drive-ui-install:
	@"$(ROOT)/Tools/install-drive-ui-update.sh" "$(DRIVE_UI_PKG)"

drive-ui-deploy: drive-ui-package
	@"$(ROOT)/Tools/install-drive-ui-update.sh" "$(DRIVE_UI_PKG)"

drive-ui-status:
	@"$(ROOT)/Tools/manage-drive-ui.sh" status

drive-stop:
	@"$(ROOT)/Tools/manage-drive-ui.sh" stop

drive-restart:
	@"$(ROOT)/Tools/manage-drive-ui.sh" restart

drive-installer:
	@mkdir -p "$(ARTIFACTS)"
	@cd "$(ROOT)/Apps/Drive" && \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" \
		EDP_APP_SIGN_IDENTITY="$(EDP_APP_SIGN_IDENTITY)" \
		EDP_SELF_SIGNED_DISTRIBUTION=1 \
		EDP_SERVICE_MODE=legacy \
		./installer/build-native-installer.sh "$(ARTIFACTS)"

drive-release-installer:
	@mkdir -p "$(ARTIFACTS)"
	@cd "$(ROOT)/Apps/Drive" && \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" \
		./installer/build-self-signed-installer.sh "$(ARTIFACTS)"
	@EDP_REQUIRE_RELEASE_SIGNING=1 \
		"$(ROOT)/Apps/Drive/scripts/verify-clean-installer.sh" \
		"$(ARTIFACTS)/EDP-Drive-0.6.0-arm64-Clean.pkg"

drive-env-status:
	@"$(ROOT)/Tools/drive-environment.sh" status

drive-clean-environment:
	@"$(ROOT)/Tools/drive-environment.sh" clean

studio-generate:
	@cd "$(ROOT)/Apps/Studio/native/EDPStudioNative" && \
		xcodegen generate --spec project.yml

studio-build:
	@mkdir -p "$(STUDIO_DERIVED_DATA)"
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild \
		-project "$(STUDIO_PROJECT)" \
		-scheme EDPStudio \
		-configuration Release \
		-derivedDataPath "$(STUDIO_DERIVED_DATA)" \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

build: drive-build studio-build

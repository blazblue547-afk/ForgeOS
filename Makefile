SHELL := /usr/bin/env bash

export ARCH ?= x86_64
export KERNEL_VERSION ?= 7.1
export BUSYBOX_VERSION ?= 1.38.0
export SYSTEMD_VERSION ?= 260
export DBUS_VERSION ?= 1.16.2
export PAM_VERSION ?= 1.7.2
export DESKTOP ?= console
export ENABLE_DESKTOP ?= 0
export ENABLE_DOOM_EMACS ?= 0
export ROOT_LABEL ?= FORGE_ROOT
export EFI_LABEL ?= FORGE_EFI
desktop_enabled := $(filter 1 true TRUE yes YES on ON,$(ENABLE_DESKTOP))
doom_emacs_enabled := $(filter 1 true TRUE yes YES on ON,$(ENABLE_DOOM_EMACS))
export IMAGE_SIZE_MIB ?= $(if $(filter gnome,$(DESKTOP)),12288,$(if $(or $(desktop_enabled),$(doom_emacs_enabled)),4096,2048))
export ESP_SIZE_MIB ?= 256
export JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
export SECURE_BOOT ?= 0
export SECURE_BOOT_KEY ?=
export SECURE_BOOT_CERT ?=
export GNOME_SUITE ?= trixie
export GNOME_MIRROR ?= http://deb.debian.org/debian

.PHONY: help deps image-deps fetch kernel busybox pam systemd dbus rootfs doom-emacs gnome-rootfs image gnome-image secure-boot-keys run run-image run-desktop run-gnome list-disks install clean distclean

help:
	@printf '%s\n' \
		'ForgeOS targets:' \
		'  make deps       - install Debian/Ubuntu host deps for rootfs + run' \
		'  make image-deps - install Debian/Ubuntu host deps for image + run-image' \
		'  make fetch      - download upstream source tarballs' \
		'  make kernel     - build the Linux kernel and stage modules' \
		'  make pam        - build Linux-PAM for login/session tracking' \
		'  make busybox    - build BusyBox rescue utilities' \
		'  make systemd    - build systemd PID 1' \
		'  make dbus       - build the D-Bus system bus daemon' \
		'  make rootfs     - assemble the systemd rootfs and initramfs' \
		'  ENABLE_DESKTOP=1 make rootfs - add Openbox/tint2/PCManFM desktop' \
		'  ENABLE_DOOM_EMACS=1 make rootfs - add Emacs + Doom Emacs tooling' \
		'  make doom-emacs - rebuild rootfs with the Doom Emacs layer enabled' \
		'  make gnome-rootfs - assemble a Debian GNOME desktop rootfs' \
		'  make image      - build a bootable GPT/UEFI disk image' \
		'  make gnome-image - build a bootable GPT/UEFI GNOME disk image' \
		'  make secure-boot-keys - generate a local Secure Boot signing keypair' \
		'  make run        - boot kernel + initramfs in QEMU' \
		'  make run-image  - boot the UEFI disk image in QEMU' \
		'  ENABLE_DESKTOP=1 make run-desktop - boot the Openbox desktop image' \
		'  make run-gnome  - boot the GNOME image in graphical QEMU' \
		'  make list-disks - list candidate installation disks' \
		'  sudo make install DISK=/dev/sdX - install ForgeOS to a real disk' \
		'  make clean      - remove build, staging, and output artifacts' \
		'  make distclean  - also remove downloaded and extracted sources'

deps:
	@./scripts/install-deps.sh

image-deps:
	@./scripts/install-image-deps.sh

fetch:
	@./scripts/fetch-sources.sh

kernel: fetch
	@./scripts/build-kernel.sh

busybox: fetch
	@./scripts/build-busybox.sh

pam: fetch
	@./scripts/build-pam.sh

systemd: fetch
	@./scripts/build-systemd.sh

dbus: fetch
	@./scripts/build-dbus.sh

rootfs:
	@./scripts/build-rootfs.sh

doom-emacs: ENABLE_DOOM_EMACS = 1
doom-emacs: rootfs

gnome-rootfs: DESKTOP = gnome
gnome-rootfs: IMAGE_SIZE_MIB = 12288
gnome-rootfs:
	@./scripts/build-gnome-rootfs.sh

image:
	@./scripts/build-image.sh

gnome-image: DESKTOP = gnome
gnome-image: IMAGE_SIZE_MIB = 12288
gnome-image:
	@./scripts/build-image.sh

secure-boot-keys:
	@./scripts/generate-secure-boot-keys.sh

run:
	@./scripts/run-qemu.sh direct

run-image:
	@./scripts/run-qemu.sh image

run-desktop: ENABLE_DESKTOP = 1
run-desktop: IMAGE_SIZE_MIB = 4096
run-desktop: MEMORY_MB = 3072
run-desktop: image
	@./scripts/run-qemu.sh image-gui

run-gnome: DESKTOP = gnome
run-gnome: IMAGE_SIZE_MIB = 12288
run-gnome: MEMORY_MB = 4096
run-gnome: gnome-image
	@./scripts/run-qemu.sh image-gui

list-disks:
	@./scripts/install-to-disk.sh --list

install:
	@./scripts/install-to-disk.sh --device "$(DISK)" $(INSTALL_ARGS)

clean:
	@./scripts/clean.sh

distclean: clean
	@rm -rf downloads sources

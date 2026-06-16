# ForgeOS Architecture

## Goal

ForgeOS defaults to a CLI-only operating system for `x86_64` desktops and laptops that does not use an existing Linux distribution as its base. It composes upstream projects directly:

- Linux kernel for the kernel layer
- systemd for PID 1 and service supervision
- D-Bus for the system message bus
- Linux-PAM for local login authentication and session hooks
- BusyBox for `/bin/sh`, early switch-root support, and compact rescue tools
- Nix for core package management
- optional Doom Emacs tooling for an editor-focused user environment
- custom units and configuration files from this repository

There is also an optional `DESKTOP=gnome` image flavor. That flavor keeps the ForgeOS kernel, GRUB/EFI boot flow, image builder, and kernel modules, but uses a Debian `trixie` GNOME userspace because GNOME's dependency closure is much larger than the current source-built ForgeOS userspace.

The normal ForgeOS rootfs can also be built with `ENABLE_DESKTOP=1`. That does not switch to a new OS flavor: it keeps the source-built ForgeOS userspace and stages an Openbox/tint2/PCManFM desktop layer into the same rootfs.

The normal rootfs can also be built with `ENABLE_DOOM_EMACS=1`. That keeps the same ForgeOS userspace and stages a Doom Emacs tool layer into it rather than switching to a distro flavor.

## Boot Model

ForgeOS currently targets UEFI systems.

1. The disk image contains a GPT.
2. Partition 1 is a FAT32 EFI System Partition labeled `FORGE_EFI`.
3. By default, `out/BOOTX64.EFI` is a standalone GRUB UEFI fallback loader with a small debug boot menu.
4. The built kernel EFI stub is copied to `EFI/BOOT/FORGEOS.EFI`.
5. UEFI firmware executes GRUB from `EFI/BOOT/BOOTX64.EFI`, and GRUB starts the kernel.
6. The built-in kernel command line mounts `PARTLABEL=root` as the real root filesystem.
7. systemd starts as `/sbin/init`, activates the D-Bus system bus, starts `systemd-logind`, `systemd-resolved`, and `systemd-networkd`, reaches `multi-user.target`, and launches PAM-backed login prompts on `tty1` and `ttyS0`.

## Root Filesystem Model

The root filesystem is assembled in `staging/rootfs` from:

- systemd install output from `staging/systemd`
- D-Bus install output from `staging/dbus`
- Linux-PAM install output from `staging/pam`
- runtime library dependencies copied from the native build host for systemd, D-Bus, PAM, and BusyBox binaries
- BusyBox install output for shell and rescue utilities
- the official Nix `x86_64-linux` binary tarball staged into `/nix/store`
- kernel modules from the kernel build
- the repository overlay in `overlay/rootfs`

The default network path uses DHCP through `systemd-networkd`. DNS servers learned from DHCP are exposed through `systemd-resolved`, and `/etc/resolv.conf` is a symlink to the resolved-managed compatibility file at `/run/systemd/resolve/resolv.conf`. Tools that query systemd over D-Bus use the system bus at `/run/dbus/system_bus_socket`. The source-built systemd layer also includes `systemd-logind`, `loginctl`, `pam_systemd.so`, the `org.freedesktop.login1` system-bus policy, and the logind varlink socket. Console login uses BusyBox `getty` and `login`; `/etc/pam.d/login` authenticates against `/etc/shadow` with `pam_unix.so` and registers sessions with `pam_systemd.so`.

Nix is integrated as a multi-user daemon package manager in the normal ForgeOS rootfs. `scripts/stage-nix.sh` copies the official Nix store closure into `/nix/store`, stages `nix.conf`, adds `nixbld` build accounts, enables `forgeos-nix-bootstrap.service`, and exposes `nix-daemon.service` plus `nix-daemon.socket`. On first boot, the bootstrap service fixes `/nix` ownership, loads the bundled `.reginfo` into the Nix database, and creates the default profile with Nix, Nix manual pages, and the bundled CA certificate package. ForgeOS enables `nix-command` and `flakes`, uses `cache.nixos.org`, and leaves Nix build sandboxing disabled until the OS has a verified sandbox policy.

The default console build also generates `out/rootfs.cpio.gz` for quick QEMU smoke tests. Desktop-enabled rootfs builds skip the initramfs artifact and boot through the ext4 root partition image.

For `DESKTOP=gnome`, `scripts/build-gnome-rootfs.sh` uses `mmdebstrap` or root-run `debootstrap` to assemble a Debian GNOME root filesystem in `staging/rootfs`, adds ForgeOS identity defaults, creates the initial desktop user, enables GDM and NetworkManager, and copies ForgeOS kernel modules. The GNOME image path deliberately does not copy `rootfs.cpio.gz` into the EFI System Partition because a desktop rootfs is too large for the initramfs-based smoke-test flow.

For `ENABLE_DESKTOP=1`, `scripts/stage-openbox-desktop.sh` asks apt to download the Openbox desktop package closure, extracts only the runtime payloads into `staging/rootfs`, skips base daemon packages that would replace source-built systemd or D-Bus, and enables `forgeos-desktop.service` on `tty1`.

For `ENABLE_DOOM_EMACS=1`, `scripts/stage-doom-emacs.sh` stages Emacs, Git, ripgrep, GNU find, fd, CA certificates, and the upstream Doom Emacs Git checkout. The Doom checkout is stored globally at `/usr/share/doom-emacs`; `/etc/profile.d/doom-emacs.sh` seeds `~/.config/emacs` and `~/.config/doom` for each writable user home on first shell login. The per-user Doom package cache is intentionally not baked into the image; users initialize it with `doom sync` inside the running OS.

## Why EFI Stub Boot

The project can still boot the kernel EFI stub directly with `BOOTLOADER=stub`, which keeps the implementation smaller and more direct:

- no external distro boot stack
- no dependency on GRUB or systemd-boot
- one kernel artifact doubles as the EFI executable

The tradeoff is that the current implementation depends on a built-in kernel command line.

## Secure Boot Model

ForgeOS supports a signed EFI-stub loader path for machines where the signing certificate has been enrolled in firmware Secure Boot `db`, or imported through a trusted shim/MOK flow.

This does not make ForgeOS trusted by stock Microsoft Secure Boot keys. That would require a Microsoft-signed shim or another trusted first-stage loader. The current project keeps the direct EFI-stub model and signs that EFI executable with a user-controlled key.

## Hardware Scope

The kernel fragment forces built-in support for:

- UEFI boot
- serial and virtual terminals
- devtmpfs
- ext4 and vfat
- GPT partition tables
- AHCI / SATA
- NVMe
- USB storage
- common keyboard and USB input paths
- common QEMU virtio paths

This is enough for a first CLI OS image and a development boot path, but not yet a broad hardware certification matrix.

## Known Gaps

- BIOS boot path
- Microsoft/shim-signed Secure Boot chain
- measured boot and full verified boot
- full laptop Wi-Fi and firmware coverage
- declarative NixOS-style system rebuilds and rollback management
- pre-synced per-user Doom Emacs package caches
- source-built GNOME and graphical desktop dependency closure
- source-built Openbox/Xorg/GTK graphical dependency closure
- source-built dependency closure for systemd and D-Bus runtime libraries
- account management beyond the built-in `forge` and `root` users
- in-OS guided installer and update system
- hardening review of the kernel and userspace defaults

## Suggested Next Steps

1. Add a source-built libc and dependency sysroot so systemd no longer needs copied host libraries.
2. Teach the installer to support target-specific kernel command lines so multiple ForgeOS disks can coexist more safely.
3. Add network profiles, SSH, and a ForgeOS system update mechanism on top of Nix.
4. Expand kernel coverage for Wi-Fi, Bluetooth, audio, suspend, and vendor input devices.

# ForgeOS Architecture

## Goal

ForgeOS defaults to a CLI-only operating system for `x86_64` desktops and laptops that does not use an existing Linux distribution as its base. It composes upstream projects directly:

- Linux kernel for the kernel layer
- systemd for PID 1 and service supervision
- D-Bus for the system message bus
- Linux-PAM for local login authentication and session hooks
- BusyBox for `/bin/sh`, early switch-root support, and compact rescue tools
- Nix for core package management
- custom units and configuration files from this repository

There is also an optional `DESKTOP=gnome` image flavor. That flavor keeps the ForgeOS kernel, GRUB/EFI boot flow, image builder, and kernel modules, but uses a Debian `trixie` GNOME userspace because GNOME's dependency closure is much larger than the current source-built ForgeOS userspace.

The normal ForgeOS rootfs can also be built with `ENABLE_DESKTOP=1`. That does not switch to a new OS flavor: it keeps the source-built ForgeOS userspace and stages an Openbox/tint2/PCManFM desktop layer into the same rootfs.

## Boot Model

ForgeOS currently targets UEFI systems.

1. The disk image contains a GPT.
2. Partition 1 is a FAT32 EFI System Partition labeled `FORGE_EFI`.
3. Partition 2 is the current ext4 base OS slot labeled `FORGE_ROOT` with GPT partition label `root`.
4. Normal atomic images reserve additional read-only base OS slots for rollback selection. With the default `ROLLBACK_SLOTS=2`, partition 3 is labeled `FORGE_ROOT_1` with GPT partition label `root-rollback`.
5. The ext4 writable app/state partition is labeled `FORGE_APPS` with GPT partition label `apps`. With the default rollback layout it is partition 4; with `ROLLBACK_SLOTS=1` it is partition 3.
6. By default, `out/BOOTX64.EFI` is a standalone GRUB UEFI fallback loader with a small debug boot menu.
7. The built kernel EFI stub is copied to `EFI/BOOT/FORGEOS.EFI`.
8. UEFI firmware executes GRUB from `EFI/BOOT/BOOTX64.EFI`, and GRUB starts the kernel.
9. The default menu mounts `PARTLABEL=root` as the real root filesystem with `ro` so the current base OS stays atomic.
10. The GRUB rollback selector can instead boot another base slot such as `PARTLABEL=root-rollback`.
11. systemd starts as `/sbin/init`, mounts the app layer at `/forge`, bind-mounts mutable paths from it, activates the D-Bus system bus, starts `systemd-logind`, `systemd-resolved`, and `systemd-networkd`, reaches `multi-user.target`, and launches PAM-backed login prompts on `tty1` and `ttyS0`.

## Root Filesystem Model

The canonical root filesystem is assembled in `staging/rootfs` from:

- systemd install output from `staging/systemd`
- D-Bus install output from `staging/dbus`
- Linux-PAM install output from `staging/pam`
- runtime library dependencies copied from the native build host for systemd, D-Bus, PAM, and BusyBox binaries
- BusyBox install output for shell and rescue utilities
- the official Nix `x86_64-linux` binary tarball staged into `/nix/store`
- kernel modules from the kernel build
- the repository overlay in `overlay/rootfs`

For normal ForgeOS disk images, `scripts/build-image.sh` derives two trees from `staging/rootfs`:

- `staging/rootfs-base`: the read-only base OS copied into each base slot
- `staging/appfs`: the writable app/state layer used for the `apps` partition

The base tree keeps the source-built OS, boot-critical tools, systemd units, configuration, and symlinks into `/nix/store`. The app/state tree owns `/nix`, `/home`, `/root`, `/var`, `/opt`, and `/usr/local`. The image builder writes an `/etc/fstab` into `staging/rootfs-base` that mounts `LABEL=FORGE_APPS` at `/forge` and bind-mounts those paths back into the normal filesystem layout. `/tmp` is a tmpfs. The canonical `staging/rootfs` used for `rootfs.cpio.gz` does not include those app-layer fstab entries, so the direct initramfs smoke-test path stays monolithic and does not wait for a disk app partition.

## Rollback Selection

Atomic ForgeOS images build `ROLLBACK_SLOTS=2` by default. Slot 0 is the normal current base at `PARTLABEL=root`; slot 1 is a rollback base at `PARTLABEL=root-rollback`. Additional slots can be requested with higher `ROLLBACK_SLOTS` values and receive GPT labels such as `root-rollback-2`.

The GRUB fallback loader emits a `ForgeOS rollback selector` submenu with entries for each base slot. On console images, the main selector entry for each slot uses the initramfs-assisted handoff path with fixed framebuffer settings so a recovery boot stays visible even when the direct kernel path cannot mount the requested slot or loses display output. Each slot also has normal-display and direct-kernel entries for comparison. The early `forgeos-switch-root` helper parses the selected `root=` or `forgeos.root=` argument so it switches into the requested `PARTLABEL`, `LABEL`, `UUID`, `PARTUUID`, or explicit `/dev/...` root device instead of assuming the current slot.

`BOOTLOADER=stub` signs or copies the kernel EFI stub directly and therefore has no interactive rollback menu. The default kernel build does not bake in a root slot, so the stub path requires a kernel built with `CONFIG_CMDLINE_BOOL=y` or firmware-provided EFI load options.

The `forgeos-rollback` command provides the first in-OS management layer for these slots. It can list slots, copy the currently booted base into an inactive rollback slot with `forgeos-rollback create`, and promote a booted rollback slot back to `root` with `forgeos-rollback promote`. Slot copying is block-level, so the source root should be mounted read-only and the destination slot must be unmounted.

If `tune2fs` is available, `forgeos-rollback` randomizes the destination filesystem UUID and restores the expected filesystem label after copying. Without `tune2fs`, the copy still works for GRUB selection because boot entries use GPT partition labels, but the command warns that the ext4 UUID and label may still match the source.

ForgeOS still needs a declarative NixOS-style base OS rebuild/update flow that prepares a new base deployment and calls this slot machinery automatically.

The default network path uses DHCP through `systemd-networkd`. DNS servers learned from DHCP are exposed through `systemd-resolved`, and `/etc/resolv.conf` is a symlink to the resolved-managed compatibility file at `/run/systemd/resolve/resolv.conf`. Tools that query systemd over D-Bus use the system bus at `/run/dbus/system_bus_socket`. The source-built systemd layer also includes `systemd-logind`, `loginctl`, `pam_systemd.so`, the `org.freedesktop.login1` system-bus policy, and the logind varlink socket. Console login uses BusyBox `getty` and `login`; `/etc/pam.d/login` authenticates against `/etc/shadow` with `pam_unix.so` and registers sessions with `pam_systemd.so`.

Nix is integrated as a multi-user daemon package manager in the normal ForgeOS app layer. `scripts/stage-nix.sh` copies the official Nix store closure into `/nix/store`, stages `nix.conf`, adds `nixbld` build accounts, enables `forgeos-nix-bootstrap.service`, and exposes `nix-daemon.service` plus `nix-daemon.socket`. On disk images, the image builder moves that `/nix` tree into `staging/appfs` so package installs and Nix state mutate the app partition, not the base OS. On first boot, the bootstrap service fixes `/nix` ownership, loads the bundled `.reginfo` into the Nix database, and creates the default profile with Nix, Nix manual pages, and the bundled CA certificate package. ForgeOS enables `nix-command` and `flakes`, uses `cache.nixos.org`, and leaves Nix build sandboxing disabled until the OS has a verified sandbox policy.

The default console build also generates `out/rootfs.cpio.gz` for quick QEMU smoke tests. That direct initramfs path is intentionally monolithic and writable because it has no persistent app partition. Desktop-enabled rootfs builds skip the initramfs artifact and boot through the ext4 disk image path.

For `DESKTOP=gnome`, `scripts/build-gnome-rootfs.sh` uses `mmdebstrap` or root-run `debootstrap` to assemble a Debian GNOME root filesystem in `staging/rootfs`, adds ForgeOS identity defaults, creates the initial desktop user, enables GDM and NetworkManager, and copies ForgeOS kernel modules. The GNOME image path deliberately does not copy `rootfs.cpio.gz` into the EFI System Partition because a desktop rootfs is too large for the initramfs-based smoke-test flow.

For `ENABLE_DESKTOP=1`, `scripts/stage-openbox-desktop.sh` asks apt to download the Openbox desktop package closure, extracts only the runtime payloads into `staging/rootfs`, skips base daemon packages that would replace source-built systemd or D-Bus, and enables `forgeos-desktop.service` on `tty1`.

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
- declarative NixOS-style system rebuilds and automated rollback-slot population
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

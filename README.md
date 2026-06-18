# ForgeOS

ForgeOS is a custom `x86_64` operating system project that defaults to a CLI-only source-built userspace instead of an existing Linux distribution tree. It uses the Linux kernel as the kernel layer, systemd as PID 1, BusyBox as a compact shell/rescue utility set, a custom root filesystem overlay, and direct UEFI boot through the kernel EFI stub. An optional GNOME desktop image flavor is available through a Debian package bootstrap.

As of `2026-06-17`, the project defaults to:

- Linux kernel `7.1`
- systemd `260`
- D-Bus `1.16.2`
- BusyBox `1.38.0`
- Linux-PAM `1.7.2`
- Nix `2.34.0` as the core package manager
- `amd64` / `x86_64` only
- 64-bit only
- UEFI boot
- text console only
- optional GNOME desktop image using Debian `trixie` packages

## What This Repository Produces

- a reproducible build pipeline for a from-scratch OS image
- a minimal root filesystem with systemd as `/sbin/init`
- a bootable GPT disk image with:
  - an EFI system partition
  - a read-only ext4 base root partition
  - a writable ext4 app/state partition
- a faster QEMU smoke-test path using `kernel + initramfs`

## Layout

- `config/`: kernel and BusyBox configuration fragments
- `docs/`: architecture and limitations
- `overlay/rootfs/`: files copied into the root filesystem
- `scripts/`: fetch, build, image, and run scripts

## Quick Start

```bash
cd /home/joe/forgeos
sudo scripts/install-deps.sh
make rootfs
make run
```

That dependency script is for Debian/Ubuntu hosts and installs only the packages needed for the console rootfs plus direct QEMU boot path. The build path then builds the kernel, Linux-PAM, systemd, D-Bus, BusyBox rescue tools, and a compressed initramfs, then boots it directly in QEMU over serial.

The default console accounts are `forge` and `root`; both use the password `forge`. Console logins go through BusyBox `login`, Linux-PAM, and `pam_systemd.so`, so `systemd-logind` tracks real per-user sessions.

Nix is staged into the writable ForgeOS app layer as the core package manager. Disk images boot a read-only base OS and bind the app layer over `/nix`, `/home`, `/root`, `/var`, `/opt`, and `/usr/local`. On first boot, `forgeos-nix-bootstrap.service` registers the initial `/nix/store` closure, creates the default Nix profile, and starts `nix-daemon`. Log in as `forge` and install apps with the friendly wrapper:

```bash
forgeos-app install hello
hello
```

The wrapper uses Nix profiles underneath, so direct Nix commands still work:

```bash
nix profile install nixpkgs#hello
```

If `forgeos-app` says `nix is unavailable`, check whether the app layer mounted:

```bash
forgeos-app status
lsblk -f
```

On an installed system with a `FORGE_APPS` partition, recover the current boot as root:

```bash
mount LABEL=FORGE_APPS /forge
mount -a
systemctl restart forgeos-nix-bootstrap.service nix-daemon.socket nix-daemon.service
```

To build a UEFI disk image:

```bash
cd /home/joe/forgeos
sudo scripts/install-image-deps.sh
make image
make run-image
```

To add a lightweight desktop to the normal ForgeOS rootfs, enable the Openbox desktop layer:

```bash
cd /home/joe/forgeos
ENABLE_DESKTOP=1 make image
ENABLE_DESKTOP=1 make run-desktop
```

This keeps the regular ForgeOS rootfs path and stages Openbox, tint2, PCManFM, Xorg, fonts, icons, and a terminal into it. The serial login prompt remains on `ttyS0`; `tty1` starts the desktop session.

To build a GNOME desktop image, install `mmdebstrap` on the host and use the GNOME targets:

```bash
cd /home/joe/forgeos
make gnome-image
make run-gnome
```

The GNOME image uses ForgeOS's kernel and boot image flow with a Debian `trixie` GNOME userspace. The default desktop account is `forge` with password `forge`, and GDM autologin is enabled by default. Override `GNOME_USER`, `GNOME_USER_PASSWORD`, `GNOME_AUTOLOGIN=0`, `GNOME_SUITE`, `GNOME_MIRROR`, or `IMAGE_SIZE_MIB` when building if needed.

To list candidate installation disks:

```bash
cd /home/joe/forgeos
make list-disks
```

To install ForgeOS to a real disk from a Linux host:

```bash
cd /home/joe/forgeos
sudo make install DISK=/dev/nvme0n1
```

## Build Notes

- The root filesystem is not copied from a distro. It is assembled from upstream systemd, upstream D-Bus, upstream Linux-PAM, upstream BusyBox rescue tools, copied runtime library dependencies for systemd, D-Bus, PAM, and BusyBox, and the files in `overlay/rootfs/`.
- The default removable-media boot path uses GRUB at `EFI/BOOT/BOOTX64.EFI` and keeps the kernel EFI stub at `EFI/BOOT/FORGEOS.EFI`.
- The built-in kernel command line targets `PARTLABEL=root` and keeps Intel graphics modesetting enabled, with a couple of laptop display workarounds for newer firmware.
- For default direct QEMU testing, `scripts/run-qemu.sh direct` uses the generated `rootfs.cpio.gz`.
- The host-side installer expands the writable app/state partition to fill larger target disks. The base root partition stays fixed-size and read-only at runtime.
- systemd is installed as `/sbin/init`. BusyBox remains available for `/bin/sh`, PAM-backed `/bin/login`, early switch-root support, and emergency command-line tools.
- Nix `2.34.0` is staged from the official `x86_64-linux` binary tarball and configured in multi-user daemon mode with `/nix`, `nixbld` build users, `cache.nixos.org`, and `nix-command`/`flakes` enabled. The `/nix` tree lives in the mutable app layer on disk images. Override `NIX_VERSION` or `NIX_SYSTEM` if you intentionally want a different upstream tarball.
- A ForgeOS-native `neofetch` command is included in the overlay with a custom ForgeOS ASCII logo at `/usr/share/neofetch/ascii/distro/forgeos`.
- The console starts PAM-backed login prompts on `tty1` and `ttyS0` through native systemd units instead of BusyBox `inittab`.
- The system bus is provided by source-built `dbus-daemon` and socket-activated at `/run/dbus/system_bus_socket`.
- `systemd-logind` is included in the source-built systemd layer, owns `org.freedesktop.login1` on the system bus, and provides `loginctl` plus the logind varlink socket. `pam_systemd.so` registers console logins as logind sessions.
- DHCP networking is handled by `systemd-networkd`; DNS is handled by `systemd-resolved`, with `/etc/resolv.conf` linked to `/run/systemd/resolve/resolv.conf`.
- `ENABLE_DESKTOP=1` adds an Openbox/tint2/PCManFM desktop layer to the normal ForgeOS rootfs by extracting a minimal Debian package payload while preserving the source-built systemd and D-Bus daemons.
- `DESKTOP=gnome` switches rootfs assembly to a Debian package bootstrap because GNOME depends on a large desktop stack that ForgeOS does not source-build yet.

Set `BOOTLOADER=stub` when building an image to use the direct kernel EFI-stub fallback path instead of GRUB.

## Secure Boot Signing

ForgeOS can build a Secure Boot-compatible fallback loader by signing the kernel EFI stub before it is copied to `EFI/BOOT/BOOTX64.EFI`.

Generate a local signing keypair:

```bash
cd /home/joe/forgeos
make secure-boot-keys
```

Build a signed disk image:

```bash
cd /home/joe/forgeos
SECURE_BOOT=1 \
SECURE_BOOT_KEY=out/secure-boot/ForgeOS.key \
SECURE_BOOT_CERT=out/secure-boot/ForgeOS.crt \
make image
```

The host needs `sbsign` for signed builds. Enroll `out/secure-boot/ForgeOS.cer` in the target firmware Secure Boot database, or import it through a trusted shim/MOK flow, before booting the image with Secure Boot enabled. The generated private key should stay private; anyone with it can sign EFI binaries trusted by machines where the certificate is enrolled.

## Toolchain Notes

Linux-PAM, systemd, and D-Bus are built with Meson/Ninja and staged dynamically. BusyBox is also built dynamically so its `login` applet can load PAM modules. The build copies the ELF runtime library closure from the native build host into the root filesystem, so cross-building the userspace is not supported yet.

## Current Limits

- UEFI only for now; BIOS boot is not implemented.
- The kernel config includes common desktop, laptop, and QEMU storage/input paths, but not every vendor driver.
- Wireless firmware, GPU acceleration, stock Microsoft-trusted Secure Boot/shim integration, audio, and power-management polish are not bundled yet.
- Nix is the package manager for the mutable app layer, but ForgeOS does not yet have a declarative NixOS-style base OS rebuild/update flow or rollback selector.
- Account management is limited to the built-in `forge` and `root` accounts.
- The Openbox desktop layer is a staged runtime payload, not an in-OS package manager.
- GNOME support is currently a package-bootstrapped desktop flavor, not a source-built ForgeOS desktop stack.
- The installer is host-side only; there is no in-OS guided installer yet.

More detail is in [docs/ARCHITECTURE.md](/home/joe/forgeos/docs/ARCHITECTURE.md).
Installer usage is documented in [docs/INSTALLER.md](/home/joe/forgeos/docs/INSTALLER.md).

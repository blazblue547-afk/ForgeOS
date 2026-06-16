# ForgeOS Installer

ForgeOS currently ships with a host-side installer script:

- [scripts/install-to-disk.sh](/home/joe/forgeos/scripts/install-to-disk.sh)

It installs the built raw ForgeOS image to a real block device from an existing Linux host.

## What It Does

1. validates that the target is a disk
2. refuses to overwrite obvious active system storage
3. optionally unmounts non-critical target partitions
4. writes the ForgeOS raw image to the target disk
5. repairs the GPT backup header on larger disks
6. expands partition `2` and the ext4 root filesystem to fill the device
7. randomizes the ext4 root filesystem UUID by default

## Basic Usage

List candidate disks:

```bash
cd /home/joe/forgeos
make list-disks
```

Install to a disk:

```bash
cd /home/joe/forgeos
sudo make install DISK=/dev/nvme0n1
```

Non-interactive install:

```bash
cd /home/joe/forgeos
sudo make install DISK=/dev/sdc INSTALL_ARGS="--yes --unmount"
```

Install without expanding the root filesystem:

```bash
cd /home/joe/forgeos
sudo make install DISK=/dev/sdc INSTALL_ARGS="--no-expand-root"
```

## Direct Script Usage

```bash
sudo ./scripts/install-to-disk.sh --device /dev/sdc
```

Optional arguments:

- `--image /path/to/forgeos.img`
- `--yes`
- `--unmount`
- `--no-expand-root`
- `--keep-root-uuid`

## Secure Boot Images

To install a Secure Boot-compatible image, build it with a signed EFI loader first:

```bash
cd /home/joe/forgeos
make secure-boot-keys
SECURE_BOOT=1 \
SECURE_BOOT_KEY=out/secure-boot/ForgeOS.key \
SECURE_BOOT_CERT=out/secure-boot/ForgeOS.crt \
make image
sudo make install DISK=/dev/sdc
```

Enroll `out/secure-boot/ForgeOS.cer` in the target firmware Secure Boot database, or through a trusted shim/MOK flow, before booting with Secure Boot enabled. Without that enrollment, firmware should reject `EFI/BOOT/BOOTX64.EFI` even though it is signed.

## Safety Notes

- The installer is destructive. It erases the target disk.
- Run it from a Linux host, not from the disk you are installing over.
- The current boot model uses a built-in kernel command line with `root=PARTLABEL=root`.
- Avoid leaving multiple ForgeOS installations attached during early testing, because multiple disks with the same GPT partition label can confuse root selection.
- Secure Boot trust is tied to the enrolled signing certificate. Protect the generated private key.

## Current Limitation

This is a host-side installer, not an in-OS guided installer yet. There is no partitioning UI, user setup wizard, or live environment workflow in this version.

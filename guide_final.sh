# The disk that will be used
# NOTE: If installing on an nvme drive (ie: /dev/nvme0n1), you'll need to replace all occurrences of ${DISK}# with ${DISK}p# where # is the partition number.
# Don't forget to also replace all occurences of $(echo $DISK | cut -f1 -d\ )# with $(echo $DISK | cut -f1 -d\ )p#
export DISK='/dev/nvme0n1'

export KEY_DISK=/dev/mapper/cryptkey

# /boot (EFI) partition (2GB) (p0)
# LUKS key partition (20MB) (p1)
# LUKS swap partition (32GB) (p2)
# ZFS root partition (Remaining space) (p3)
# NOTE: Make the ZFS root partition your last partition, so that if you resize the disk it will be easy to get ZFS to use the extra space
parted --script --align optimal $DISK -- \
    mklabel gpt \
    mkpart 'EFI' fat32 1MiB 2049MiB set 1 esp on \
    mkpart 'luks-key' 2049MiB 2069MiB \
    mkpart 'luks-swap' 2069MiB 34837MiB \
    mkpart 'zfs-pool' 34837MiB 100%

# tr -d '\n' < /dev/urandom | dd of=/dev/disk/by-partlabel/key
# Create an encrypted disk to hold our key, the key to this drive
# is what you'll type in to unlock the rest of your drives... so,
# remember it:
export DISK1_KEY=$(echo $DISK | cut -f1 -d\ )1
cryptsetup luksFormat $DISK1_KEY
cryptsetup luksOpen $DISK1_KEY cryptkey

# Write the key right to the decrypted LUKS partition, as raw bytes
echo "" > newline
dd if=/dev/zero bs=1 count=1 seek=1 of=newline
dd if=/dev/urandom bs=32 count=1 | od -A none -t x | tr -d '[:space:]' | cat - newline > hdd.key
dd if=/dev/zero of=$KEY_DISK
dd if=hdd.key of=$KEY_DISK
dd if=$KEY_DISK bs=64 count=1

# Format swap as encrypted LUKS and mount the partition
export DISK1_SWAP=$(echo $DISK | cut -f1 -d\ )2
cryptsetup luksFormat --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP
cryptsetup open --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP cryptswap
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap

# Create root pool
zpool create -f \
	-o ashift=12 \
	-o autotrim=on \
	-R /mnt \
	-O acltype=posixacl \
	-O compression=zstd \
	-O dnodesize=auto \
	-O normalization=formD \
	-O xattr=sa \
	-O atime=off \
	-O canmount=off \
	-O mountpoint=none \
	-O encryption=aes-256-gcm \
	-O keylocation=file://$KEY_DISK \
	-O keyformat=hex \
	rpool \
	${DISK}p3

# Create root system containers
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/local
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/safe

# Create and mount dataset for `/`
zfs create -p -o mountpoint=legacy rpool/local/root
# Create a blank snapshot
zfs snapshot rpool/local/root@blank
# Mount root ZFS dataset
mount -t zfs rpool/local/root /mnt

# Create and mount dataset for `/nix`
zfs create -p -o mountpoint=legacy rpool/local/nix
mkdir -p /mnt/nix
mount -t zfs rpool/local/nix /mnt/nix

# Create and mount dataset for `/home`
zfs create -p -o mountpoint=legacy rpool/safe/home
mkdir -p /mnt/home
mount -t zfs rpool/safe/home /mnt/home

# Create and mount dataset for `/persist`
zfs create -p -o mountpoint=legacy rpool/safe/persist
mkdir -p /mnt/persist
mount -t zfs rpool/safe/persist /mnt/persist

# Create and mount dataset for `/boot`
zfs create -o mountpoint=legacy bpool/root
mkdir -p /mnt/boot
mount -t zfs bpool/root /mnt/boot

# Mount EFI partition
mkdir -p /mnt/boot
mkfs.vfat -F32 $(echo $DISK | cut -f1 -d\ )p1
mount -t vfat $(echo $DISK | cut -f1 -d\ )p1 /mnt/boot

# Generate initial system configuration
nixos-generate-config --root /mnt

export CRYPTKEY="$(blkid -o export "$DISK1_KEY" | grep "^UUID=")"
export CRYPTKEY="${CRYPTKEY#UUID=*}"

export CRYPTSWAP="$(blkid -o export "$DISK1_SWAP" | grep "^UUID=")"
export CRYPTSWAP="${CRYPTSWAP#UUID=*}"

# Set root password
export rootPwd=$(mkpasswd -m SHA-512 -s "root")

# Import ZFS-specific configuration
sed -i "s|./hardware-configuration.nix|./hardware-configuration.nix ./zfs.nix|g" /mnt/etc/nixos/configuration.nix
# Write zfs.nix configuration
tee -a /mnt/etc/nixos/zfs.nix <<EOF
{ config, pkgs, lib, ... }:

{ boot.supportedFilesystems = [ "zfs" ];
	# Kernel modules needed for mounting LUKS devices in initrd stage
	boot.initrd.availableKernelModules = [ "aesni_intel" "cryptd" ];

	boot.initrd.luks.devices = {
		cryptkey = {
			device = "/dev/disk/by-uuid/$CRYPTKEY";
		};

		cryptswap = {
			device = "/dev/disk/by-uuid/$CRYPTSWAP";
			keyFile = "$KEY_DISK";
			keyFileSize = 64;
		};
	};

	networking.hostId = "$(head -c 8 /etc/machine-id)";
	boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

	boot.initrd.postDeviceCommands = lib.mkAfter ''
		zfs rollback -r rpool/local/root@blank
	'';

    boot.loader.systemd-boot.enable = true;
    systemd.services.zfs-mount.enable = false;

	users.users.root.initialHashedPassword = "$rootPwd";
}
EOF

# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
reboot

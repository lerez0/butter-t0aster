#!/bin/bash

set -e
LOG_FILE="/var/log/butter-t0aster.log"

if [[ $EUID -eq 0 && -z "$SUDO_USER" ]]; then
    echo "🛑 This script must be run with sudo, not as the root user directly "
    echo "   Please retry with: sudo $0 "
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo "🛑 This script requires sudo privileges "
    echo "   Please retry with: sudo $0 "
    exit 1
fi

echo ""
echo ""
echo "========================================================="
echo "                                                         "
echo "  🌀 This sm00th script will make a Debian server        "
echo "     (with butter file system BTRFS) ready for:          "
echo "                                                         "
echo "       📸 /root partition snapshots                      "
echo "       🛟  automatic backups of /home partition          "
echo "       💈 preserving SSDs lifespan                       "
echo "       😴 stay active when laptop lid is closed          "
echo "                                                         "
echo "========================================================="
echo "                                                         "
echo "     👀 if any step fails, the script will exit          "
echo "                                                         "
echo "     🗞  and logs will be printed for review from:       "
echo "         👉 ${LOG_FILE}                                  "
echo "                                                         "
echo "========================================================="
echo ""
echo ""

echo "🗞  Let's start it all by creating a log file to trap errors "
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
error_handler() {
    echo "🛑 error occurred - exit script "
    if [ -f "$LOG_FILE" ]; then
      echo "   ======== BEGIN LOGS ========   "
      cat "$LOG_FILE"
      echo "   ========  END LOGS  ========   "
    else
      echo "⚠️  no log file found at $LOG_FILE "
    fi
    exit 1
}

trap 'error_handler' ERR
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""

echo "📦 make sure required packages are installed (btrfs-progs) "
apt-get update
apt-get install btrfs-progs -y --no-install-recommends
echo ""

echo "1️⃣  create mount points 🪄 "
ROOT_MOUNT_POINT="/mnt"
HOME_MOUNT_POINT="/mnt/home"
mkdir -p "$ROOT_MOUNT_POINT"
if [ $? -ne 0 ]; then
    echo "🛑 could not create $ROOT_MOUNT_POINT "
    exit 1
fi
mkdir -p "$HOME_MOUNT_POINT"
if [ $? -ne 0 ]; then
    echo "🛑 could not create $HOME_MOUNT_POINT "
    exit 1
fi
echo "✅ mount points created successfully "
echo ""

echo "🔎 check current partition layout "
lsblk -o NAME,FSTYPE,MOUNTPOINT | tee -a "$LOG_FILE"
echo ""

echo "🔎 look for BTRFS subvolumes "
btrfs subvolume list / || echo "   ❌ no subvolumes detected on / "
btrfs subvolume list /home || echo "   ❌ no subvolumes detected on /home "
echo ""

echo "2️⃣  detect /root and /home partitions ⏫ "
DISK_ROOT=$(findmnt -n -o SOURCE -T / | awk -F'[' '{print $1}')
DISK_HOME=$(findmnt -n -o SOURCE -T /home | awk -F'[' '{print $1}')
if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
    echo "🛑 /root and /home partitions not detected "
    exit 1
fi
echo "📀 detected /root partition: $DISK_ROOT"
echo "📀 detected /home partition: $DISK_HOME"
echo ""
read -p "   ❓ are these partitions correct? (y/n): " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "👎 partition detection aborted "; exit 1; }
HOME_PERMISSIONS=$(stat -c "%a" /home)
echo ""
echo "💡 initial /home permissions saved: $HOME_PERMISSIONS "
echo ""

echo "3️⃣  ensure mount points exist 🏗️ "
mkdir -p /mnt
mkdir -p /mnt/home
echo "✅ mount points created "
echo ""

echo "4️⃣  ensure BTRFS subvolumes exist 🧈 "
echo "   first, mount /home partition "
mount "$DISK_HOME" /mnt/home || { echo "🛑 failed to mount /home temporarily "; exit 1; }
echo "   and back up its content"
mkdir -p /tmp/home_backup
cp -a /home/* /tmp/home_backup/ || { echo "🛑 failed to backup home contents "; exit 1; }
echo ""
if ! btrfs subvolume list /mnt/home | grep -q "@home"; then
    echo "   @home subvolume not found: "
    btrfs subvolume create /mnt/home/@home
    echo "🔁 restore /home content to @home subvolume "
    cp -a /tmp/home_backup/* /mnt/home/@home/ || { echo "🛑 failed to restore home contents "; exit 1; }
fi
if [[ -d /tmp/home_backup ]]; then
    rm -rf /tmp/home_backup
fi
umount /mnt/home
echo "✅ BTRFS subvolume @home OK "
echo ""

echo "5️⃣  mount /root and /home in optimised BTRFS subvolumes ⏫ "
mount -o subvol=@rootfs "$DISK_ROOT" /mnt || { echo "🛑 failed to mount /root "; exit 1; }
if ! findmnt /home &>/dev/null; then
    mount -o subvol=@home "$DISK_HOME" /home || { echo "🛑 failed to mount /home "; exit 1; }
else
    echo "    ✅ /home is already mounted: skip remount "
fi
echo "✅ /root and /home partitions mounted successfully "
echo ""

echo "6️⃣  configure /etc/fstab for persistence 💾 "
UUID_ROOT=$(blkid -s UUID -o value "$DISK_ROOT")
UUID_HOME=$(blkid -s UUID -o value "$DISK_HOME")
sed -i "/\/home.*btrfs.*/d" /etc/fstab
sed -i "/\/.*btrfs.*/d" /etc/fstab
echo "UUID=$UUID_ROOT /      btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@rootfs 0 1" | tee -a /etc/fstab
echo "UUID=$UUID_HOME /home  btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@home  0 2" | tee -a /etc/fstab
echo "✅ /etc/fstab updated successfully."
echo ""

echo "✌️ butter optimisation is complete "
echo ""
echo "🔃 please reboot to apply BTRFS mounts "
echo "   then run t0aster: "
echo "   👉 sudo bash /home/$SUDO_USER/t0aster.sh "
echo ""
echo "🗞  logs are available at: $LOG_FILE "
echo ""
echo "   made with ⏳ by le rez0.net "
echo "   💌 please return love and experience at https://github.com/lerez0/butter-t0aster/issues "
echo ""
read -p "❓ reboot now? (y/n): " reboot_response
if [[ "$reboot_response" == "y" ]]; then
  reboot now
else
  echo ""
  echo "🔃 reboot is required to apply changes "
  echo "   to reboot, run: "
  echo "   👉 sudo reboot now "
  echo ""
fi
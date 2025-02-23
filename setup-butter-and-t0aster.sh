#!/bin/bash

# this one

set -e
LOG_FILE="/var/log/butter-t0aster.log" # define log file

if [[ $EUID -eq 0 && -z "$SUDO_USER" ]]; then
    echo "🛑 This script must be run with sudo, not as the root user directly"
    echo "   Please retry with: sudo $0"
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo "🛑 This script requires sudo privileges"
    echo "   Please retry with: sudo $0"
    exit 1
fi

ACTUAL_USER="$SUDO_USER" # identify actual sudo user
if [ -z "$ACTUAL_USER" ]; then
    ACTUAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}')
fi
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# disclaimer
echo ""
echo ""
echo ""
echo "========================================================="
echo "                                                         "
echo "  🌀 This sm00th script will make a Debian 12 server     "
echo "      with butter file system (BTRFS) ready for:         "
echo "       📸 /root partition snapshots                      "
echo "       🛟  automatic backups of /home partition          "
echo "       💈 preserving SSDs lifespan                       "
echo "       😴 stay active when laptop lid is closed          "
echo "                                                         "
echo "========================================================="
echo "                                                         "
echo "  👀  if any step fails, the script will exit            "
echo "  🗞  and logs will be printed for review from:          "
echo "      👉 ${LOG_FILE}                                     "
echo "                                                         "
echo "========================================================="
echo ""
echo ""
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "🗞  Let's start it all by creating a log file to trap errors"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
error_handler() {
    echo "🛑 error occurred - exit script"
    if [ -f "$LOG_FILE" ]; then
      echo "======== BEGIN LOGS ========"
      cat "$LOG_FILE" # print the log file
      echo "========  END LOGS  ========"
    else
      echo "⚠️  no log file found at $LOG_FILE"
    fi
    exit 1
}

trap 'error_handler || true' ERR # set up error trap
exec > >(tee -a "$LOG_FILE") 2>&1 # redirect outputs to log file
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣  create mount points 🪄"
ROOT_MOUNT_POINT="/mnt" # print mount point for /root
HOME_MOUNT_POINT="/mnt/home" # print mount point for /home

mkdir -p "$ROOT_MOUNT_POINT" # ensure /root mount point exists
if [ $? -ne 0 ]; then
    echo "🛑 ERROR could not create $ROOT_MOUNT_POINT"
    exit 1
fi

mkdir -p "$HOME_MOUNT_POINT" # ensure /home mount point exists
if [ $? -ne 0 ]; then
    echo "🛑 ERROR could not create $HOME_MOUNT_POINT"
    exit 1
fi

echo "✅ mount points created successfully"
echo ""

echo "🔎 check current partition layout"
lsblk -o NAME,FSTYPE,MOUNTPOINT | tee -a "$LOG_FILE"
echo ""

echo "🔎 look for BTRFS subvolumes"
btrfs subvolume list / || echo "No subvolumes detected on /"
btrfs subvolume list /home || echo "No subvolumes detected on /home"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "2️⃣  detecte /root and /home partitions ⏫"
DISK_ROOT=$(findmnt -n -o SOURCE -T / | awk -F'[' '{print $1}')
DISK_HOME=$(findmnt -n -o SOURCE -T /home | awk -F'[' '{print $1}')

if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
    echo "🛑 ERROR /root and /home partitions not detected"
    exit 1
fi

echo "📀 detected /root partition: $DISK_ROOT"
echo "📀 detected /home partition: $DISK_HOME"
echo ""

read -p "  Are these partitions correct? (y/n): " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Partition detection aborted."; exit 1; }

HOME_PERMISSIONS=$(stat -c "%a" /home)
echo ""
echo "💡 Initial /home permissions saved: $HOME_PERMISSIONS"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "3️⃣  ensure mount points exist 🏗️"
mkdir -p /mnt
mkdir -p /mnt/home
echo "    ✅ mount points created"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "4️⃣  ensure BTRFS subvolumes exist 🧈"
echo "    first, mount /home partition"
mount "$DISK_HOME" /mnt/home || { echo "🛑 ERROR failed to mount /home temporarily"; exit 1; }

echo "    and back up its content"
mkdir -p /tmp/home_backup
cp -a /home/* /tmp/home_backup/ || { echo "🛑 ERROR failed to backup home contents"; exit 1; }

if ! btrfs subvolume list /mnt/home | grep -q "@home"; then
    echo "    @home subvolume not found - create subvolume"
    btrfs subvolume create /mnt/home/@home
    echo "    restore /home content to @home subvolume"
    cp -a /tmp/home_backup/* /mnt/home/@home/ || { echo "🛑 ERROR failed to restore home contents"; exit 1; }
fi

rm -rf /tmp/home_backup
umount /mnt/home
echo "    ✅ BTRFS subvolume @home OK"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "5️⃣  mount /root and /home in optimized BTRFS subvolumes ⏫"
# mkdir -p /mnt/home
mount -o subvol=@rootfs "$DISK_ROOT" /mnt || { echo "🛑 ERROR failed to mount /root"; exit 1; }
if ! findmnt /home &>/dev/null; then
    mount -o subvol=@home "$DISK_HOME" /home || { echo "🛑 ERROR failed to mount /home"; exit 1; }
else
    echo "✅ /home is already mounted, skipping remount."
fi

chmod "$HOME_PERMISSIONS" /mnt/home
echo "    🔐 /home permissions restored to: $HOME_PERMISSIONS"
echo "    ✅ /root and /home partitions mounted successfully"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "6️⃣  configure /etc/fstab for persistence 💾"
UUID_ROOT=$(blkid -s UUID -o value "$DISK_ROOT")
UUID_HOME=$(blkid -s UUID -o value "$DISK_HOME")
sudo sed -i "/\/home.*btrfs.*/d" /etc/fstab # remove incorrect entries
sudo sed -i "/\/.*btrfs.*/d" /etc/fstab

echo "📝 write fstab entries"
echo "UUID=$UUID_ROOT /      btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@rootfs 0 1" | tee -a /etc/fstab
echo "UUID=$UUID_HOME /home  btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@home  0 2" | tee -a /etc/fstab
echo "✅ /etc/fstab updated successfully."

echo "🔄 remount /root and /home"
mount -o remount,compress=zstd "$DISK_ROOT" /
mount -o remount,compress=zstd "$DISK_HOME" /home
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "7️⃣  install snapshot tools and create '0 initial snapshot' for /root (to keep for ever) 📸"
apt-get update # update packages lists

echo "📦 install SNAPPER"
if ! apt-get install -y snapper btrfs-progs git make; then
    echo "🛑 SNAPPER installation failed" >&2
    exit 1
fi

echo "📦 install GRUB-BTRFS from source"
    echo "🛑 grub-btrfs installation from backports failed" >&2
if [ -d "/tmp/grub-btrfs" ]; then
    rm -rf /tmp/grub-btrfs
fi

if ! git clone https://github.com/Antynea/grub-btrfs.git /tmp/grub-btrfs; then
    echo "🛑 failed to clone grub-btrfs from repository" >&2
    exit 1
fi

cd /tmp/grub-btrfs

echo "📦 Installing dependencies for GRUB-BTRFS..."
apt-get install -y grub-common grub-pc-bin grub2-common make gcc || {
    echo "🛑 ERROR: Failed to install dependencies for GRUB-BTRFS" >&2
    exit 1
}

if ! make install; then
    echo "🛑 GRUB-BTRFS installation failed" >&2
    exit 1
fi

echo "📝 configure SNAPPER for /root"
if ! snapper -c root create-config /; then
    echo "🛑 SNAPPER configuration failed" >&2
    exit 1
fi


echo "   check /.snapshots BTRFS subvolume state"
if ! btrfs subvolume show /.snapshots &>/dev/null; then
    echo "📂 create BTRFS subvolume for SNAPPER"
    if ! btrfs subvolume create /.snapshots; then
        echo "🛑 /.snapshots subvolume creation failed" >&2
        exit 1
    fi
fi

echo "   configuring snapshot policies"
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_CLEANUP=yes"
snapper -c root set-config "TIMELINE_MIN_AGE=1800"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=0"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=2"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=2"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"

echo "   enable SNAPPER automatic snapshots"
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer

if ! snapper -c root create --description "00 initial server snapshot"; then
    echo "🛑 initial snapshot failed" >&2
    exit 1
fi
echo "✅ initial snapshot for /root created"

echo "📸 configuring GRUB-BTRFS for boot snapshots"
if ! systemctl enable --now grub-btrfsd; then
    echo "🟠 enable GRUB-BTRFS service failed" >&2
    echo "   this is not critical - let's continue"
fi

echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
if ! update-grub; then
    echo "🟠 GRUB update failed" >&2
    echo "   this is not critical - let's continue"
fi

echo "✅ SNAPPER and GRUB-BTRFS installation complete"
echo ""

echo "   To list previous snapshots, run:"
echo "      👉 sudo snapper -c root list"
echo "   To rollback to a previous snapshot, use:"
echo "      👉 sudo snapper rollback <snapshot_number>"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "8️⃣  install ZRAM tools to compress swap in RAM 🗜"
apt-get install zram-tools -y # install ZRAM tools

echo "   configure ZRAM with 25% of RAM and compression"
cat <<EOF > /etc/default/zramswap # configure ZRAM settings
ZRAM_PERCENTAGE=25
COMPRESSION_ALGO=zstd
PRIORITY=10
EOF

echo "   start ZRAM on system boot"
systemctl start zramswap # start ZRAM now
systemctl enable zramswap # start ZRAM on boot
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "9️⃣  set swappiness to 10 📝"
sysctl vm.swappiness=10 # set swappiness value
echo "vm.swappiness=10" >> /etc/sysctl.conf  # make swappiness persistent
sysctl vm.swappiness=10 # apply change now
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 0️⃣  plan SSD trim once a week 💈"
echo "0 0 * * 0 fstrim /" | tee -a /etc/cron.d/ssd_trim # schedule SSD trim with a cron job
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 1️⃣  set up automatic backups when 'backups' USB is inserted 🛟"
echo "📝 create backup script"
BACKUP_SCRIPT='/usr/local/bin/auto_backup.sh'
cat <<EOF > $BACKUP_SCRIPT # write backup script
#!/bin/bash
TARGET="/media/backups"
LOG_FILE="/var/log/backup.log"
mkdir -p \$TARGET # create backup target
rsync -aAXv --delete --exclude={"/lost+found/*","/mnt/*","/media/*","/var/cache/*","/proc/*","/tmp/*","/dev/*","/run/*","/sys/*"} / \$TARGET/ >> \$LOG_FILE 2>&1 # perform backup
echo "🛟 backup completed at \$(date)" >> \$LOG_FILE # log completion timestamp
EOF
chmod +x $BACKUP_SCRIPT # make backup script executable

echo "   set udev rule for USB detection"
UDEV_RULE='/etc/udev/rules.d/99-backup.rules'
cat <<EOF > $UDEV_RULE # create udev rule
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="backups", RUN+="$BACKUP_SCRIPT"
EOF
udevadm control --reload-rules && udevadm trigger
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 2️⃣  disable sleep when lid is closed (in logind.conf) 💡"
while true; do
    read -p "    Do you want the laptop to remain active when the lid is closed? (y/n): " lid_response
    case $lid_response in
        [yYnN]) break ;;
        *) echo "    answer 'y' or 'n'" ;;
    esac
done

if [[ "$lid_response" == "y" || "$lid_response" == "Y" ]]; then
  echo "     configure the laptop to remain active with the lid closed"
  cat <<EOF | sudo tee /etc/systemd/logind.conf
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF
  sudo systemctl restart systemd-logind
else
  echo "     skip closed lid configuration"
fi
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 3️⃣  disable suspend and hibernation 😴"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do # ignore sleep triggers
    systemctl mask "$target"
    systemctl disable "$target"
done
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 4️⃣  take automatic snapshots before automatic security upgrades 📸"
echo "       if automatic security updates have been activated during OS install"
if dpkg -l | grep -q unattended-upgrades; then
  echo "    configure snapshot hook for unattended-upgrades"
  echo 'DPkg::Pre-Invoke {"btrfs subvolume snapshot / /.snapshots/pre-update-$(date +%Y%m%d%H%M%S)";};' | sudo tee /etc/apt/apt.conf.d/99-btrfs-snapshot-before-upgrade > /dev/null
else
  echo "    automatic security upgrades are not installed; skip"
fi
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 5️⃣  create '01 optimised server snapshot' 📸"
snapper -c root create --description "01 optimised server snapshot"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "1️⃣ 6️⃣  create 'post-reboot-system-check' script 🧰"
echo ""
echo "       Run this second script manually after reboot"
echo "       to ensure butter-t0aster ran fine"

if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(logname 2>/dev/null || who am i | awk '{print $1}')
    # Fallback if all else fails
    if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
        echo "Warning: Could not determine the actual user. Using current directory."
        CURRENT_USER="$(ls -l /home | grep -v total | head -1 | awk '{print $3}')"
    fi
fi

USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
CHECK_SCRIPT="$USER_HOME/post-reboot-system-check.sh"

cat <<'EOF' > "$CHECK_SCRIPT"
#!/bin/bash
if [[ $EUID -ne 0 ]]; then
   echo "🛑 This script must be run as root/with sudo"
   echo "   Please retry with: sudo $0"
   exit 1
fi

echo "🧰 run post-reboot system check"

echo "🔎 check BTRFS subvolumes"
btrfs subvolume list /
echo ""

echo "🔎 check fstab entries"
grep btrfs /etc/fstab
echo ""

echo "🔎 check SNAPPER configurations"
snapper -c root list
echo ""

echo "🔎 check GRUB-BTRFS detection"
ls /boot/grub/
echo ""

echo "🔎 check for failed services"
systemctl --failed
echo ""

echo "🔎 check disk usage"
df -h
echo ""

echo "✅ post-reboot system check complete"
echo ""

read -p "🗑️ remove both scripts? (y/n): " cleanup_response
if [[ "$cleanup_response" == "y" || "$cleanup_response" == "Y" ]]; then
    rm "$0"
    rm "$(dirname "$0")/butter-t0aster.sh" 2>/dev/null
    echo "✅ scripts removed"
else
    echo "   To remove these scripts later, run: "
    echo "   👉 rm $0"
    echo "   👉 rm $(dirname "$0")/butter-t0aster.sh"
fi
EOF

chmod +x "$CHECK_SCRIPT" # allow script execution
chown "$CURRENT_USER:$(id -gn "$CURRENT_USER")" "$CHECK_SCRIPT"
echo ""

echo "✅ post-reboot script has been created at: $CHECK_SCRIPT"
echo "   after reboot, run it manually with:"
echo "   👉 sudo bash $CHECK_SCRIPT"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "🏁 setup is complete"
echo ""
read -p "   reboot now? (y/n): " reboot_response
if [[ "$reboot_response" == "y" ]]; then
  reboot now
else
  echo ""
  echo "🔃 reboot is required to apply changes"
  echo "   to reboot, run: "
  echo "   👉 reboot now "
  echo "📸 to manually trigger a snapshot at any time, run:"
  echo "   👉 sudo btrfs subvolume snapshot / /.snapshots/manual-$(date +%Y%m%d%H%M%S)"
  echo "🗞  logs are available at: $LOG_FILE"
  echo ""
  echo "   made with ⏳ by le rez0.net"
  echo "   please return experience and issues at https://github.com/lerez0"
  echo ""
fi

#!/bin/bash

set -e

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
echo "  👀 If any step fails, the script will exit             "
echo "     and logs will be printed for review from:           "
echo "      👉 $LOG_FILE                                       "
echo "                                                         "
echo "========================================================="
echo ""
echo ""
echo ""

echo "Let's start it all by creating a log file to trap errors"
LOG_FILE="/var/log/butter-t0aster.log" # define log file
error_handler() {
    echo "An error occurred. Exiting script. Review the logs below:"
    echo "======== BEGIN LOGS ========"
    cat "$LOG_FILE" # print the log file
    echo "======== END LOGS ========"
    exit 1
}

trap error_handler ERR # set up error trap
exec > >(tee -a "$LOG_FILE") 2>&1 # redirect outputs to log file

if [[ $(/usr/bin/id -u) -ne 0 ]]; then # check for root privilege
   echo "This script must be run by a sudo user with root permissions. Please retry."
   exit 1
fi

echo "🔎 check current partition layout"
lsblk -o NAME,FSTYPE,MOUNTPOINT | tee -a "$LOG_FILE"
echo ""

echo "🔎 look for BTRFS subvolumes"
btrfs subvolume list / || echo "No subvolumes detected on /"
btrfs subvolume list /home || echo "No subvolumes detected on /home"
echo ""

echo "WARNING unmounting /root and /home will clean subvolumes and reset partition layout"
echo "As your server being freshly installed, you shouldn't have any data to lose yet 🤞"
echo ""
read -p "Do you wish to continue? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "✋ script aborted"
    exit 0
fi

echo "🚧 unmount and clean subvolumes"
umount /home || echo "✅ no /home partition mounted"
umount / || echo "✅ no /root partition mounted"
echo ""

mount /dev/sda2 /mnt
btrfs subvolume delete /mnt/@rootfs || echo "@rootfs not found"
btrfs subvolume delete /mnt/@home || echo "@home not found"
echo ""

umount /mnt
echo "✅ partitions are clean"
echo ""

echo "🔎 check /root and /home paths"
DISK_ROOT=$(findmnt -n -o SOURCE -T /)
DISK_HOME=$(findmnt -n -o SOURCE -T /home)
echo ""

echo "1. mount /root and /home partitions ⏫"
DISK_ROOT=$(findmnt -n -o SOURCE -T /)
DISK_HOME=$(findmnt -n -o SOURCE -T /home)
echo ""

if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
  echo "ERROR root and home partitions not detected"
  echo "Attempting to detect unmounted BTRFS partitions..."
  echo ""
  
  while IFS= read -r line; do
    PARTITION=$(echo "$line" | awk -F '=' '/DEVNAME/{print $2}' | tr -d '"')
    FS_TYPE=$(echo "$line" | awk -F '=' '/TYPE/{print $2}' | tr -d '"')

    if [[ $FS_TYPE == "btrfs" ]]; then
        if [[ -z "$DISK_ROOT" ]]; then
            echo "👉 potential /root partition detected: $PARTITION"
            echo ""
            DISK_ROOT="$PARTITION"
        elif [[ -z "$DISK_HOME" ]]; then
            echo "👉 potential /home partition detected: $PARTITION"
            echo ""
            DISK_HOME="$PARTITION"
        fi
    fi
  done < <(blkid -o export)

  if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
    echo "ERROR /root and /home partitions could not be reliably detected"
    exit 1
  fi
fi

echo "detected /root partition: $DISK_ROOT"
echo "detected /home partition: $DISK_HOME"
echo ""

while true; do
    read -p "Are these partitions correct? (y/n): " confirm
    case $confirm in
        [yY]) break ;;
        [nN])
            echo "Partition detection aborted. Please verify your disk layout and try again."
            exit 1 ;;
        *)
            echo "Please answer y or n." ;;
    esac
done 

ROOT_MOUNT_POINT="/mnt" # print mount point for /root
HOME_MOUNT_POINT="/mnt/home" # print mount point for /home

mkdir -p $ROOT_MOUNT_POINT # ensure /root mount point exists
mkdir -p $HOME_MOUNT_POINT # ensure /home mount point exists

HOME_PERMISSIONS=$(stat -c "%a" /home) # save initial permissions of /home
echo "💡 Initial /home permissions saved: $HOME_PERMISSIONS"

mount $DISK_ROOT $ROOT_MOUNT_POINT # mount /root partition
mount $DISK_HOME $HOME_MOUNT_POINT # mount /home partition

echo "2. create BTRFS subvolumes 🧈"
btrfs subvolume create $ROOT_MOUNT_POINT/@ # create /root subvolume
umount $ROOT_MOUNT_POINT # unmount root partition
btrfs subvolume create $HOME_MOUNT_POINT/@home # create /home subvolume
umount $HOME_MOUNT_POINT # unmount home partition

echo "3. remount /root and /home with subvolumes ⏫"
mount -o subvol=@ $DISK_ROOT / # remount /root with subvolume
mkdir -p /home
mount -o subvol=@home $DISK_HOME /home # remount /home with subvolume

chmod $HOME_PERMISSIONS /home # restore initial /home permissions
echo "🔐 /home permissions restored to: $HOME_PERMISSIONS"

echo "✅ /root and /home partitions mounted"

echo "4. update /etc/fstab with SSD-friendly options (backup up original fstab) 💾"
cp /etc/fstab /etc/fstab.bak # backup fstab
UUID_ROOT=$(blkid -s UUID -o value $DISK_ROOT) # fetch UUID for root
UUID_HOME=$(blkid -s UUID -o value $DISK_HOME) # fetch UUID for home
echo "UUID=$UUID_ROOT /      btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@     0 1" | tee -a /etc/fstab # update fstab for root
echo "UUID=$UUID_HOME /home  btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@home 0 2" | tee -a /etc/fstab # update fstab for home

echo "5. first snapshot for /root (to keep for ever) 📸"
SNAPSHOT_DIR="/.snapshots"
mkdir -p $SNAPSHOT_DIR # create snapshot directory
chmod 700 $SNAPSHOT_DIR # ensure only root acces to the snapshot directory
btrfs subvolume create $SNAPSHOT_DIR # create snapshot subvolume
btrfs subvolume snapshot / $SNAPSHOT_DIR/initial # create initial snapshot
echo "📸 initial snapshot for /root created"

echo "6. install ZRAM tools to compress swap in RAM 🗜"
apt update # update packages lists
apt install zram-tools -y # install ZRAM tools

echo "configure ZRAM with 25% of RAM and compression"
cat <<EOF > /etc/default/zramswap # configure ZRAM settings
ZRAM_PERCENTAGE=25
COMPRESSION_ALGO=zstd
PRIORITY=10
EOF

echo "start ZRAM on system boot"
systemctl start zramswap # start ZRAM now
systemctl enable zramswap # start ZRAM on boot

echo "7. set swappiness to 10 📝"
sysctl vm.swappiness=10 # set swappiness value
echo "vm.swappiness=10" >> /etc/sysctl.conf  # make swappiness persistent
sysctl vm.swappiness=10 # apply change now

echo "8. plan SSD trim once a week 💈"
echo "0 0 * * 0 fstrim /" | tee -a /etc/cron.d/ssd_trim # schedule SSD trim with a cron job

echo "9. set up automatic backups when 'backups' USB is inserted 🛟"

echo "create backup script"
BACKUP_SCRIPT='/usr/local/bin/auto_backup.sh'
cat <<EOF > $BACKUP_SCRIPT # write backup script
#!/bin/bash
TARGET="/media/backups"
LOG_FILE="/var/log/backup.log"
mkdir -p \$TARGET # create backup target
rsync -aAXv --delete --exclude={"/lost+found/*","/mnt/*","/media/*","/var/cache/*","/proc/*","/tmp/*","/dev/*","/run/*","/sys/*"} / \$TARGET/ >> \$LOG_FILE 2>&1 # perform backup
echo "backup completed at \$(date)" >> \$LOG_FILE # log completion timestamp
EOF
chmod +x $BACKUP_SCRIPT # make backup script executable

echo "set udev rule for USB detection"
UDEV_RULE='/etc/udev/rules.d/99-backup.rules'
cat <<EOF > $UDEV_RULE # create udev rule
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="backups", RUN+="$BACKUP_SCRIPT"
EOF
udevadm control --reload-rules

echo "10. disable sleep when lid is closed (in logind.conf) 💡"
while true; do
    read -p "Do you want to configure the laptop to remain active when the lid is closed? (y/n): " lid_response
    case $lid_response in
        [yYnN]) break ;;
        *) echo "Please answer y or n." ;;
    esac
done

if [[ "$lid_response" == "y" || "$lid_response" == "Y" ]]; then
  echo "configure the laptop to remain active with the lid closed"
  cat <<EOF | sudo tee /etc/systemd/logind.conf
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF
  sudo systemctl restart systemd-logind
else
  echo "skip closed lid configuration"
fi

echo "11. disable suspend and hibernation 😴"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target # ignore sleep triggers

echo "12. take automatic snapshots before automatic security upgrades 📸"
echo "    if automatic security updates have been activated during OS install"
if dpkg -l | grep -q unattended-upgrades; then
  echo "configure snapshot hook for unattended-upgrades"
  sudo tee /etc/apt/apt.conf.d/99-btrfs-snapshot-before-upgrade <<EOF
DPkg::Pre-Invoke {"btrfs subvolume snapshot / /.snapshots/pre-update-\$(date +%Y%m%d%H%M%S)";};
EOF
else
  echo "automatic security upgrades are not installed; skip"
fi

read -p "✅ Setup is now complete. Do you want to reboot now? (y/n): " reboot_response
if [[ "$reboot_response" == "y" ]]; then
  reboot
else
  echo "please, reboot soon to apply changes"
fi

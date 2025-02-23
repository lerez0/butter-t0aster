#!/bin/bash

set -e
LOG_FILE="/var/log/butter-t0aster.log" # Centralized log file

# Ensure script runs as root
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "🛑 This script must be run by a sudo user with root permissions."
    echo "   Please retry."
    exit 1
fi

# Centralized variables for mount points and partitions
ROOT_MOUNT_POINT="/mnt"
HOME_MOUNT_POINT="/mnt/home"
DISK_ROOT=$(findmnt -n -o SOURCE -T / | awk -F'[' '{print $1}')
DISK_HOME=$(findmnt -n -o SOURCE -T /home | awk -F'[' '{print $1}')

# Error handler to log and exit on failures
error_handler() {
    echo "🛑 Error occurred - exiting script."
    if [ -f "$LOG_FILE" ]; then
        echo "======== BEGIN LOGS ========"
        cat "$LOG_FILE"
        echo "========  END LOGS  ========"
    else
        echo "⚠️  No log file found at $LOG_FILE."
    fi
    exit 1
}

trap 'error_handler' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

# Display disclaimer
echo -e "\n\n========================================================="
echo "  🌀 This sm00th script will make a Debian 12 server"
echo "      with butter file system (BTRFS) ready for:"
echo "       📸 /root partition snapshots"
echo "       🛟  automatic backups of /home partition"
echo "       💈 preserving SSDs lifespan"
echo "       😴 stay active when laptop lid is closed"
echo "========================================================="
echo "  👀  If any step fails, the script will exit."
echo "  🗞  Logs will be printed for review from:"
echo "      👉 $LOG_FILE"
echo "=========================================================\n\n"

# Step 1: Create mount points
echo "1️⃣  Creating mount points 🪄"
mkdir -p "$ROOT_MOUNT_POINT" "$HOME_MOUNT_POINT" || { echo "🛑 Failed to create mount points."; exit 1; }
echo "✅ Mount points created successfully.\n"

# Step 2: Detect /root and /home partitions
echo "2️⃣  Detecting /root and /home partitions ⏫"
if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
    echo "🛑 ERROR: /root and /home partitions not detected."
    exit 1
fi

echo "📀 Detected /root partition: $DISK_ROOT"
echo "📀 Detected /home partition: $DISK_HOME\n"

read -p "  Are these partitions correct? (y/n): " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Partition detection aborted."; exit 1; }

HOME_PERMISSIONS=$(stat -c "%a" /home)
echo "💡 Initial /home permissions saved: $HOME_PERMISSIONS\n"

# Step 3: Ensure BTRFS subvolumes exist
echo "3️⃣  Ensuring BTRFS subvolumes exist 🧈"
mount "$DISK_HOME" "$HOME_MOUNT_POINT" || { echo "🛑 Failed to mount /home temporarily."; exit 1; }

# Backup /home content
mkdir -p /tmp/home_backup
cp -a /home/* /tmp/home_backup/ || { echo "🛑 Failed to backup home contents."; exit 1; }

if ! btrfs subvolume list "$HOME_MOUNT_POINT" | grep -q "@home"; then
    echo "    @home subvolume not found - creating subvolume."
    btrfs subvolume create "$HOME_MOUNT_POINT/@home"
    cp -a /tmp/home_backup/* "$HOME_MOUNT_POINT/@home/" || { echo "🛑 Failed to restore home contents."; exit 1; }
fi

rm -rf /tmp/home_backup
umount "$HOME_MOUNT_POINT"
echo "✅ BTRFS subvolume @home OK.\n"

# Step 4: Mount /root and /home in optimized BTRFS subvolumes
echo "4️⃣  Mounting /root and /home in optimized BTRFS subvolumes ⏫"
mount -o subvol=@rootfs "$DISK_ROOT" "$ROOT_MOUNT_POINT" || { echo "🛑 Failed to mount /root."; exit 1; }
if ! findmnt /home &>/dev/null; then
    mount -o subvol=@home "$DISK_HOME" /home || { echo "🛑 Failed to mount /home."; exit 1; }
else
    echo "✅ /home is already mounted, skipping remount."
fi

chmod "$HOME_PERMISSIONS" "$HOME_MOUNT_POINT"
echo "🔐 /home permissions restored to: $HOME_PERMISSIONS"
echo "✅ /root and /home partitions mounted successfully.\n"

# Step 5: Configure /etc/fstab for persistence
echo "5️⃣  Configuring /etc/fstab for persistence 💾"
UUID_ROOT=$(blkid -s UUID -o value "$DISK_ROOT")
UUID_HOME=$(blkid -s UUID -o value "$DISK_HOME")

# Backup fstab before modifying
cp /etc/fstab /etc/fstab.bak

# Remove existing BTRFS entries (more precise regex)
sed -i "/\/.*btrfs.*/d" /etc/fstab

# Add new entries
echo "UUID=$UUID_ROOT /      btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@rootfs 0 1" | tee -a /etc/fstab
echo "UUID=$UUID_HOME /home  btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@home  0 2" | tee -a /etc/fstab

echo "✅ /etc/fstab updated successfully.\n"

# Step 6: Install snapshot tools and create initial snapshot
echo "6️⃣  Installing snapshot tools and creating initial snapshot 📸"
apt-get update || { echo "🛑 Failed to update package lists."; exit 1; }

# Install Snapper and dependencies
apt-get install -y snapper btrfs-progs || { echo "🛑 Failed to install Snapper."; exit 1; }

# Configure Snapper for /root
snapper -c root create-config / || { echo "🛑 Failed to configure Snapper."; exit 1; }

# Create initial snapshot
snapper -c root create --description "00 initial server snapshot" || { echo "🛑 Failed to create initial snapshot."; exit 1; }
echo "✅ Initial snapshot for /root created.\n"

# Step 7: Install ZRAM tools
echo "7️⃣  Installing ZRAM tools 🗜"
apt-get install -y zram-tools || { echo "🛑 Failed to install ZRAM tools."; exit 1; }

# Configure ZRAM
cat <<EOF > /etc/default/zramswap
ZRAM_PERCENTAGE=25
COMPRESSION_ALGO=zstd
PRIORITY=10
EOF

systemctl start zramswap
systemctl enable zramswap
echo "✅ ZRAM configured and started.\n"

# Step 8: Set swappiness to 10
echo "8️⃣  Setting swappiness to 10 📝"
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
echo "✅ Swappiness set to 10.\n"

# Step 9: Schedule SSD trim
echo "9️⃣  Scheduling SSD trim 💈"
echo "0 0 * * 0 fstrim /" | tee -a /etc/cron.d/ssd_trim
echo "✅ SSD trim scheduled.\n"

# Step 10: Create post-reboot system check script
echo "🔟 Creating post-reboot system check script 🧰"
CURRENT_USER=$(logname || who am i | awk '{print $1}')
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
CHECK_SCRIPT="$USER_HOME/post-reboot-system-check.sh"

cat <<'EOF' > "$CHECK_SCRIPT"
#!/bin/bash
echo "🧰 Running post-reboot system check..."

echo "🔎 Checking BTRFS subvolumes"
btrfs subvolume list /
echo ""

echo "🔎 Checking fstab entries"
grep btrfs /etc/fstab
echo ""

echo "🔎 Checking Snapper configurations"
snapper -c root list
echo ""

echo "🔎 Checking GRUB-BTRFS detection"
ls /boot/grub/
echo ""

echo "🔎 Checking for failed services"
systemctl --failed
echo ""

echo "🔎 Checking disk usage"
df -h
echo ""

echo "✅ Post-reboot system check complete."
EOF

chmod +x "$CHECK_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$CHECK_SCRIPT"
echo "✅ Post-reboot script created at: $CHECK_SCRIPT\n"

# Final step: Reboot prompt
echo "🏁 Setup is complete."
read -p "   Reboot now? (y/n): " reboot_response
if [[ "$reboot_response" == "y" ]]; then
    reboot now
else
    echo "🔃 Reboot is required to apply changes."
    echo "   To reboot, run: 👉 reboot now"
    echo "📸 To manually trigger a snapshot, run:"
    echo "   👉 sudo btrfs subvolume snapshot / /.snapshots/manual-$(date +%Y%m%d%H%M%S)"
    echo "🗞  Logs are available at: $LOG_FILE"
    echo "   Made with ⏳ by le rez0.net"
    echo "   Please report issues at https://github.com/lerez0"
fi

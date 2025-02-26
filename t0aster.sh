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
echo "🗞  Continuing setup with logs at $LOG_FILE "
trap 'echo "🛑 error - see $LOG_FILE"; cat "$LOG_FILE"; exit 1' ERR
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""

echo "🔎 check if unattended-upgrades is installed "
UNATTENDED_UPGRADES_ENABLED="disabled"
if dpkg -l | grep -q unattended-upgrades; then
    if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
        UNATTENDED_UPGRADES_ENABLED="enabled"
        echo "   ✋ stop and disable unattended-upgrades for now "
        systemctl stop unattended-upgrades
        systemctl disable unattended-upgrades
    else
        echo "   unattended-upgrades is not running "
    fi
else
    echo "   unattended-upgrades is not installed "
fi

if [ -f /var/lib/dpkg/lock-frontend ]; then
    echo "   🔓 forcefully unlock dpkg "
    rm -f /var/lib/dpkg/lock-frontend
    rm -f /var/lib/dpkg/lock
fi
echo ""

echo "📦 install rsync for backups "
apt-get update
apt-get install rsync -y --no-install-recommends
echo ""

echo "7️⃣  install snapshot tools and create '0 initial snapshot' for /root (to keep for ever) 📸 "
echo "    📦 install SNAPPER "
if ! apt-get install snapper git make -y; then
    echo "    🛑 SNAPPER installation failed " >&2
    exit 1
fi
echo ""
echo "    📦 install GRUB-BTRFS from source with all dependecies "
if [ -d "/tmp/grub-btrfs" ]; then
    rm -rf /tmp/grub-btrfs
fi
if ! git clone https://github.com/Antynea/grub-btrfs.git /tmp/grub-btrfs; then
    echo "    🛑 failed to clone grub-btrfs from repository " >&2
    exit 1
fi
echo ""
cd /tmp/grub-btrfs

echo "    📦 install dependencies for GRUB-BTRFS "
apt-get install -y grub-common grub-pc-bin grub2-common make gcc inotify-tools || {
    echo "    🛑 failed to install dependencies for GRUB-BTRFS " >&2
    exit 1
}
if ! make; then
    echo "    🛑 GRUB-BTRFS build failed " >&2
    exit 1
fi
cp grub-btrfsd /usr/local/sbin/grub-btrfsd || { echo "🛑 failed to copy grub-btrfsd " >&2; exit 1; }
chmod +x /usr/local/sbin/grub-btrfsd
echo "    📝 configure GRUB-BTRFS "
cat <<EOF | tee /etc/systemd/system/grub-btrfsd.service
[Unit]
Description=Regenerate grub-btrfs.cfg with Btrfs snapshots
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/grub-btrfsd
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo""

echo "📸 configuring GRUB-BTRFS for boot snapshots "
if ! systemctl enable --now grub-btrfsd; then
    echo "🟠 enable GRUB-BTRFS service failed " >&2
    echo "   this is not critical - let's continue "
fi
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
if ! update-grub; then
    echo "🟠 GRUB update failed " >&2
    echo "   this is not critical - let's continue "
fi
echo "✅ SNAPPER and GRUB-BTRFS installation complete "
echo ""

echo "   To list snapshots, run: "
echo "     👉 sudo snapper -c root list "
echo "   To rollback to a previous snapshot, use: "
echo "     👉 sudo snapper rollback 1234_snapshot_number "
echo ""
echo "📝 configure SNAPPER for /root "
if ! snapper -c root create-config /; then
    echo "🛑 failed SNAPPER configuration " >&2
    exit 1
fi
echo "   check /.snapshots BTRFS subvolume state "
if ! btrfs subvolume show /.snapshots &>/dev/null; then
    echo "📂 create BTRFS subvolume for SNAPPER "
    if ! btrfs subvolume create /.snapshots; then
        echo "🛑 /.snapshots subvolume creation failed " >&2
        exit 1
    fi
fi
echo "   📝 configure snapshot policies"
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_CLEANUP=yes"
snapper -c root set-config "TIMELINE_MIN_AGE=1800"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=0"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=2"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=2"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"
echo "   enable SNAPPER automatic snapshots "
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer
if ! snapper -c root create --description "00 initial server snapshot"; then
    echo "🛑 initial snapshot failed" >&2
    exit 1
fi
echo "✅ initial snapshot for /root created "
echo ""

echo "8️⃣  install ZRAM tools to compress swap in RAM 🗜 "
apt-get install zram-tools -y --no-install-recommends
echo "   🛢  configure ZRAM with 25% of RAM and compression"
cat <<EOF > /etc/default/zramswap
ZRAM_PERCENTAGE=25
COMPRESSION_ALGO=lz4
PRIORITY=10
EOF
echo "   ⚡️ start ZRAM on system boot "
systemctl start zramswap
systemctl enable zramswap
echo ""

echo "9️⃣  set swappiness to 10 📝 "
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
sysctl vm.swappiness=10
echo ""

echo "1️⃣ 0️⃣  plan SSD trim once a week 💈 "
echo "@weekly root fstrim /" | tee -a /etc/cron.d/ssd_trim
echo ""

echo "1️⃣ 1️⃣  set up automatic backups when 'backups' USB is inserted 🛟 "
echo "     📝 create backup script"
BACKUP_SCRIPT='/usr/local/bin/auto_backup.sh'
cat <<EOF > $BACKUP_SCRIPT
#!/bin/bash
set -e

# Define files
TARGET="/media/backups"
LOG_FILE="/var/log/backup.log"
LOCK_FILE="/var/run/backup.lock"
mkdir -p \$TARGET

# check if another backup is running
if [ -f "\$LOCK_FILE" ]; then
    echo "⚠️ another backup is already running" >> "\$LOG_FILE"
    exit 1
fi

# create temporary lock file
touch "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"' EXIT

echo "🛟 strating backup"
rsync -aAXv --delete \
    --exclude={"/lost+found/*","/mnt/*","/media/*","/var/cache/*","/proc/*","/tmp/*","/dev/*","/run/*","/sys/*"} \
    / \$TARGET/ >> \$LOG_FILE 2>&1

echo ""
echo "🛟 backup completed at \$(date)" >> \$LOG_FILE
EOF
chmod +x $BACKUP_SCRIPT
echo "     🔌 and set udev rule for USB detection "
UDEV_RULE='/etc/udev/rules.d/99-backup.rules'
cat <<EOF > $UDEV_RULE
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="backups", RUN+="$BACKUP_SCRIPT"
EOF
udevadm control --reload-rules && udevadm trigger
echo ""

echo "1️⃣ 2️⃣  disable sleep when lid is closed (in logind.conf) 💡 "
read -p "     ❓ should the laptop remain active when its lid is closed? (y/n): " lid_response
if [[ "$lid_response" == "y" || "$lid_response" == "Y" ]]; then
  echo "       configure the laptop to remain active with the lid closed"
  cat <<EOF | tee /etc/systemd/logind.conf
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF
  systemctl restart systemd-logind
else
  echo "     skip closed lid configuration "
fi
echo ""

echo "1️⃣ 3️⃣  disable suspend and hibernation 😴 "
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    systemctl mask "$target"
done
echo ""

echo "1️⃣ 4️⃣  take automatic snapshots before automatic security upgrades 📸 "
echo "     if automatic security updates have been activated during OS install "
if [[ "$UNATTENDED_UPGRADES_ENABLED" == "enabled" ]]; then
    echo "     📝 configure snapshot hook for unattended-upgrades "
    echo 'DPkg::Pre-Invoke {"btrfs subvolume snapshot / /.snapshots/pre-update-$(date +%Y%m%d%H%M%S)";};' | tee /etc/apt/apt.conf.d/99-btrfs-snapshot-before-upgrade > /dev/null
else
  echo "     🔎 automatic security upgrades are not installed: skip "
fi
echo ""

echo "1️⃣ 5️⃣  create '01 optimised server snapshot' 📸 "
snapper -c root create --description "01 optimised server snapshot "
echo ""

echo "1️⃣ 6️⃣  run system check 🧰 "
echo "     to ensure butter and t0aster ran fine 👌 "
echo ""
echo "🔎 check BTRFS subvolumes "
btrfs subvolume list /
echo ""
echo "🔎 check fstab entries "
grep btrfs /etc/fstab
echo ""
echo "🔎 check SNAPPER configurations "
snapper -c root list
echo ""
echo "🔎 check GRUB-BTRFS detection "
ls /boot/grub/
echo ""
echo "🔎 check for failed services "
systemctl --failed
echo ""
echo "🔎 check disk usage "
df -h
echo ""
echo "✅ system check complete "
echo ""

if [[ "$UNATTENDED_UPGRADES_ENABLED" == "enabled" ]]; then
    echo "🔄 re-enable unattended-upgrades "
    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades
else
    echo ""
fi
echo ""

echo "🏁 your t0aster is set up and ready "
echo "   enjoy it while it's hot ♨️ "
echo ""
echo ""
echo "📸 to manually trigger a snapshot at any time, run: "
echo "   👉 sudo btrfs subvolume snapshot / /.snapshots/manual-$(date +%Y%m%d%H%M%S) "
echo ""
echo "🗞  logs are available at: $LOG_FILE "
echo ""
echo "   made with ⏳ by le rez0.net "
echo "   💌 please return love and experience at https://github.com/lerez0/butter-t0aster/issues "
echo ""
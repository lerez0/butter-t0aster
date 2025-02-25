#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "🛑 This script must be run as root/with sudo"
   echo "   Please retry with: sudo $0"
   exit 1
fi

echo "🧰 post-reboot system check"
cd
echo ""

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

read -p "🗑️❓ remove both scripts? (y/n): " cleanup_response
if [[ "$cleanup_response" == "y" || "$cleanup_response" == "Y" ]]; then
    rm "$0"
    rm "$HOME/setup-butter-and-t0aster.sh" 2>/dev/null || echo "⚠️ Main script not found at $HOME/setup-butter-and-t0aster.sh"
    echo "✅ scripts removed"
else
    echo "   To remove these scripts later, run: "
    echo "   👉 rm $0"
    echo "   👉 rm $HOME/setup-butter-and-t0aster.sh"
fi

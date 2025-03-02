#!/bin/bash
set -e

echo "     👉 plug in a USB drive right now to format it and label it 'backups' "
echo ""
echo "❗️ this will wipe the drive and all its data ❗️"
echo ""
read -p "   Is the USB drive plugged in❓ (y/n): " plugged

if [[ "$plugged" == "y" || "$plugged" == "Y" ]]; then
    AFTER=$(lsblk -o NAME,SIZE,TYPE | grep disk | awk '{print $1","$2}')
    NEW_DRIVE=$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort) | head -n 1)
    if [ -n "$NEW_DRIVE" ]; then
        USB_NAME=$(echo "$NEW_DRIVE" | cut -d',' -f1)
        USB_SIZE=$(echo "$NEW_DRIVE" | cut -d',' -f2)
        echo "   🔎 detected USB drive: '$USB_NAME' size: '$USB_SIZE'GB "
        read -p "      use '$USB_NAME' as 'backups'❓ (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo "   🆑  formatting /dev/$USB_NAME as Btrfs with label 'backups' "
            sudo parted /dev/$USB_NAME --script mklabel gpt mkpart primary 0% 100% || { echo "🛑 failed to partition " >&2; exit 1; }
            sudo mkfs.btrfs -f -L "backups" /dev/${USB_NAME}1 || { echo "🛑 failed to format " >&2; exit 1; }
            echo "   ✅ USB drive formatted as 'backups' "
            echo "   🔌 plug it in at anytime to trigger automatic backups 🛟 "
        else
            echo "   ⏭ skipping USB format - prepare a 'backups' drive later "
        fi
    else
        echo "   ⚠️ no new drive detected - skipping "
    fi
fi

# butter-t0aster
⚠️ project under early development - do not use yet!
> *a simple script to use right after first system boot, to mount subvolumes in a Debian BTRFS system, set up snapshots and automatic backups, in a scoop of buttery smoothness*

![butter-t0aster-illustration](./docs/butter-t0aster-illustration.webp)

## why **_butter-t0aster_** ?

Because like butter in a toaster, butter-filesystem in your drive makes homelab management smooth, efficient, and deliciously simple.

## features

- **BTRFS subvolumes** for root (`/`) and home (`/home`) partitions
- **ZRAM** (because swap in RAM is faster and c00ler)
- **_mount options_** for **SSDs** longevity (`noatime, compress=zstd,ssd`) and TRIM on disk once a week
- **snapshot** of the filesystem immediately after the installation, so you can always roll back
- **automatic backup** of `/home` directory
- **keep the system alive** even when the laptop lid is closed
- **disable sleep/hibernation** (because, well, it's a server, not a napper)

---

## prerequisites

- a freshly installed **Debian 12 bookworm** server
- *msdos* or *gpt* partition table (old BIOS/no EFI computers need msdos/MasterBootRecord and do not need a `/boot` partition)
- 2 btrfs primary partitions with `noatime` mount options
  - `/` bootable
  - `/home`
- 1 swap area of 2GB should suffice (just in case)
- **sudo** privileges (or root access) to execute the script
- **USB device** labeled "_backups_" for automatic backups
- a copy of this script or an Internet connection

---

## installation simple steps

Once the Debian installation is finished and the server has rebooted, log in with the `sudo` user account (we do not recommend using root account - and we advise to never install funny scripts like this one with the root superuser) and run `cd` to reach the `/home` directory.

1. **download the script** to the user `home` directory
   ```bash
   cd # open user /home directory
   wget https://raw.githubusercontent.com/lerez0/butter-t0aster/main/setup-butter-and-t0aster.sh
   ```

2. **make the script executable**
   ```bash
   chmod +x setup-butter-and-t0aster.sh
   ```

3. **run the script**
   ```bash
   sudo bash setup-butter-and-t0aster.sh
   ```

   This will automatically configure your system, apply all the optimisations, and reboot the server.

---

## MIY - make it your-own

Feel free to fork and edit the script to suit your needs! Want to change the snapshot frequency? Adjust the swappiness value? Or maybe add another backup target? All of that can be done by editing the `setup-butter-and-t0aster.sh` file.

---

## license

This script is under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## contributing

If you have suggestions or improvements for the script, feel free to open an issue.


---

### **enjoy our buttery smooth server setup! 🍞🧈**

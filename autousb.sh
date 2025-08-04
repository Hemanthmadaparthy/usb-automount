#!/bin/bash
set -e

# USB Auto-Mount + Cleanup Installer for Orange Pi / Raspberry Pi
# Includes clean unmount and folder cleanup logic
# Author: ChatGPT (2025-08-04)

echo "[INFO] Cleaning old installation..."
sudo systemctl stop 'usb-mount@*' 'usb-umount@*' >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/usb-mount@.service
sudo rm -f /etc/systemd/system/usb-umount@.service
sudo rm -f /etc/udev/rules.d/99-usb-mount.rules
sudo rm -f /usr/local/bin/usb-mount-handler.sh
sudo rm -f /usr/local/bin/usb-umount-handler.sh

echo "[INFO] Installing required packages..."
sudo apt-get update -qq
sudo apt-get install -y udev util-linux coreutils

echo "[INFO] Creating systemd service files..."

# Mount service
sudo tee /etc/systemd/system/usb-mount@.service > /dev/null <<'EOF'
[Unit]
Description=USB mount handler for %i
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-mount-handler.sh /dev/%i
EOF

# Unmount service
sudo tee /etc/systemd/system/usb-umount@.service > /dev/null <<'EOF'
[Unit]
Description=USB unmount handler for %i
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-umount-handler.sh /dev/%i
EOF

echo "[INFO] Writing udev rule..."
sudo tee /etc/udev/rules.d/99-usb-mount.rules > /dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", RUN+="/bin/systemctl start usb-mount@%k.service"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", RUN+="/bin/systemctl start usb-umount@%k.service"
EOF

echo "[INFO] Creating mount handler..."
sudo tee /usr/local/bin/usb-mount-handler.sh > /dev/null <<'EOF'
#!/bin/bash

DEVICE="$1"
ROOT_MOUNT_PATH="/srv/data/external"

LABEL=$(blkid -s LABEL -o value "$DEVICE")
[ -z "$LABEL" ] && LABEL="usbdrive"
MOUNT_PATH="$ROOT_MOUNT_PATH/$LABEL"

mkdir -p "$MOUNT_PATH"

USERID=$(stat -c "%u" "$ROOT_MOUNT_PATH" 2>/dev/null)
GROUPID=$(stat -c "%g" "$ROOT_MOUNT_PATH" 2>/dev/null)
USERID=${USERID:-1000}
GROUPID=${GROUPID:-1000}

mount -o uid="$USERID",gid="$GROUPID" "$DEVICE" "$MOUNT_PATH" && \
  echo "[INFO] Mounted $DEVICE to $MOUNT_PATH" || \
  echo "[ERROR] Failed to mount $DEVICE"
EOF

echo "[INFO] Creating unmount handler..."
sudo tee /usr/local/bin/usb-umount-handler.sh > /dev/null <<'EOF'
#!/bin/bash

DEVICE="$1"
ROOT_MOUNT_PATH="/srv/data/external"

# 1. Clean unmount
if mount | grep -q "$DEVICE"; then
    echo "[INFO] Unmounting $DEVICE..."
    umount "$DEVICE" 2>/dev/null || umount -l "$DEVICE" || umount -f "$DEVICE"
    sleep 2
fi

# 2. Refresh active labels
LABELS=$(blkid -o value -s LABEL)

# 3. Cleanup mount folders
for folder in "$ROOT_MOUNT_PATH"/*; do
    [ -d "$folder" ] || continue
    FOLDER_NAME=$(basename "$folder")

    # Skip if still mounted
    if mount | grep -q "$folder"; then
        echo "[INFO] Skipping $folder (still mounted)"
        continue
    fi

    # Skip if label still active
    if echo "$LABELS" | grep -qx "$FOLDER_NAME"; then
        echo "[INFO] Skipping $folder (still active label)"
        continue
    fi

    # Skip if folder is not empty
    if [ "$(ls -A "$folder" 2>/dev/null)" ]; then
        echo "[WARN] $folder is not empty. Skipping."
        continue
    fi

    echo "[INFO] Removing unused folder: $folder"
    rm -rf "$folder" 2>/dev/null || sudo -u orangepi rm -rf "$folder"
done
EOF

echo "[INFO] Finalizing setup..."
sudo chmod +x /usr/local/bin/usb-*.sh
sudo mkdir -p /srv/data/external
sudo chown -R 1000:1000 /srv/data/external
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo udevadm trigger

echo "[✅] USB auto-mount system with cleanup installed successfully!"
echo "[ℹ️] Plug in a USB drive with a label — it will auto-mount to /srv/data/external/<label>"

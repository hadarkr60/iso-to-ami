
#!/bin/bash

source ./config.env

# Function to clean up resources
cleanup() {
    echo "Cleaning up..."
    # Kill the HTTP server
    pkill -f "python3 -m http.server $HTTP_PORT"
    # Unmount the ISO
    sudo umount /mnt
    echo "Cleanup complete."
}

# Check if the ISO exists
if [ ! -f "$ISO_FILE" ]; then
    echo "ISO file not found. Downloading..."
    wget "$ISO_URL" -O "$ISO_FILE"
    if [ $? -ne 0 ]; then
        echo "Failed to download the ISO file. Exiting."
        exit 1
fi
else
    echo "ISO file already exists."
fi

# Mount the ISO file
echo "Mounting the ISO file..."
sudo mount -r "$ISO_FILE" /mnt
if [ $? -ne 0 ]; then
    echo "Failed to mount the ISO file. Exiting."
    exit 1
fi

# Create the user-data file
echo "Creating cloud-init configuration..."
cat > user-data << EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ubuntu-server
    password: "$PASSWORD"
    username: ubuntu

  ssh:
    install-server: true
    allow-pw: true

  late-commands:
    # Add ubuntu user to sudoers with NOPASSWD
    - echo "ubuntu ALL=(ALL:ALL) NOPASSWD:ALL" >> /target/etc/sudoers

    # Add SSH public key to authorized_keys
    - mkdir -p /target/home/ubuntu/.ssh
    - echo "$SSH_PUBLIC_KEY" > /target/home/ubuntu/.ssh/authorized_keys
    - chmod 600 /target/home/ubuntu/.ssh/authorized_keys
    - chmod 700 /target/home/ubuntu/.ssh
    - chown -R 1000:1000 /target/home/ubuntu/.ssh

    # Rename network interface from 'ens3' to 'eth0'
    - |
      echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$(cat /sys/class/net/ens3/address)\", NAME=\"eth0\"" > /target/etc/udev/rules.d/70-persistent-net.rules

    # Update the network configuration to use eth0
    - |
      cat <<EOF_NET > /target/etc/netplan/01-netcfg.yaml
      network:
        version: 2
        renderer: networkd
        ethernets:
          eth0:
            dhcp4: true
      EOF_NET
    # ensure ssh using password
    - |
      sed -i 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /target/etc/ssh/sshd_config


    # Enable and start SSH
    - curtin in-target --target=/target systemctl enable ssh
    - curtin in-target --target=/target systemctl start ssh

    # Apply the network changes
    - |
      curtin in-target --target=/target -- netplan apply

    # Modify GRUB to disable predictable network interface names
    - |
      if grep -q '^GRUB_CMDLINE_LINUX' /target/etc/default/grub; then
        sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /target/etc/default/grub
      else
        echo 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"' >> /target/etc/default/grub
      fi
      curtin in-target --target=/target update-grub
EOF

# Create an empty meta-data file
touch meta-data

# Start the HTTP server in the background
echo "Starting HTTP server on port $HTTP_PORT..."
python3 -m http.server "$HTTP_PORT" &
HTTP_SERVER_PID=$!

# Wait for a moment to ensure the HTTP server starts
sleep 2

# Create the disk image
echo "Creating a 5G disk image..."
truncate -s 5G "$IMAGE_FILE"

# Launch the KVM virtual machine
echo "Launching the KVM virtual machine..."
kvm -no-reboot -m 2048 \
    -drive file="$IMAGE_FILE",format=raw,cache=none,if=virtio \
    -cdrom "$ISO_FILE" \
    -kernel /mnt/casper/vmlinuz \
    -initrd /mnt/casper/initrd \
    -append "autoinstall ds=nocloud-net;s=http://_gateway:$HTTP_PORT/"

# Clean up resources
cleanup

# Phase 2: Upload the image to S3
echo "Uploading $IMAGE_FILE to S3 bucket $S3_BUCKET..."
aws s3 cp "$IMAGE_FILE" "s3://$S3_BUCKET"
if [ $? -ne 0 ]; then
    echo "Failed to upload the image to S3. Exiting."
    exit 1
fi

# Phase 3: Create a snapshot from the image
echo "Creating an import snapshot task..."
IMPORT_TASK_ID=$(aws ec2 import-snapshot \
    --description "$IMPORT_DESCRIPTION" \
    --disk-container Format=RAW,UserBucket="{S3Bucket=$S3_BUCKET,S3Key=$(basename $IMAGE_FILE)}" \
    --query 'ImportTaskId' --output text)
if [ -z "$IMPORT_TASK_ID" ]; then
    echo "Failed to create an import snapshot task. Exiting."
    exit 1
fi

echo "Import snapshot task created with ID: $IMPORT_TASK_ID"

# Wait for the import snapshot task to complete
echo "Waiting for the import snapshot task to complete..."
while true; do
    TASK_STATUS=$(aws ec2 describe-import-snapshot-tasks \
        --import-task-ids "$IMPORT_TASK_ID" \
        --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' --output text)
    if [ "$TASK_STATUS" == "completed" ]; then
        break
    elif [ "$TASK_STATUS" == "deleting" ] || [ "$TASK_STATUS" == "deleted" ]; then
        echo "Snapshot task failed. Exiting."
        exit 1
    else
        echo "Current task status: $TASK_STATUS. Waiting..."
        sleep 10
    fi
done

# Get the snapshot ID
SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
    --import-task-ids "$IMPORT_TASK_ID" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' --output text)

if [ -z "$SNAPSHOT_ID" ]; then
    echo "Failed to retrieve the snapshot ID. Exiting."
    exit 1
fi

echo "Snapshot created with ID: $SNAPSHOT_ID"

# Phase 4: Register the AMI
echo "Registering the AMI..."
AMI_ID=$(aws ec2 register-image \
    --name "$AMI_NAME" \
    --description "$AMI_DESCRIPTION" \
    --architecture x86_64 \
    --root-device-name "/dev/xvda" \
    --virtualization-type hvm \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAPSHOT_ID}" \
    --query 'ImageId' --output text)

if [ -z "$AMI_ID" ]; then
    echo "Failed to register the AMI. Exiting."
    exit 1
fi

echo "AMI registered with ID: $AMI_ID"

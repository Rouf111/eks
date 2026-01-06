#!/bin/bash
set -ex

# EKS Bootstrap - This must run first
/etc/eks/bootstrap.sh ${cluster_name}

# Configure HugePages
mkdir -p /mnt/huge
mount -t hugetlbfs nodev /mnt/huge

# Set hugepages count (1024 pages of 2MB each = 2GB total)
echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages

# Make hugepages persistent across reboots
if ! grep -q "/mnt/huge" /etc/fstab; then
  echo "nodev /mnt/huge hugetlbfs defaults 0 0" >> /etc/fstab
fi

# Configure hugepages in sysctl for persistence
cat > /etc/sysctl.d/99-hugepages.conf <<EOF
vm.nr_hugepages = 1024
EOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-hugepages.conf

# Verify hugepages configuration
echo "HugePages configured:"
cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages

# Restart kubelet to apply changes
systemctl restart kubelet

echo "HugePages configuration complete"

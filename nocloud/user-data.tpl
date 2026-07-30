#cloud-config
output: {all: '| tee -a /var/log/cloud-init-output.log /dev/console'}
#
# Build-time NoCloud seed — consumed ONCE by cloud-init inside the
# Packer build VM.
#
# Responsibilities:
#   1. Create the ephemeral Packer SSH user so the communicator can
#      connect (the only thing cloud-init MUST do here).
#   2. Grow the root partition/fs to fill the disk Packer resized to.
#
# Everything else — packages, hardening files, service enablement,
# firewall rules — is handled by Packer provisioner blocks in
# golden-image.pkr.hcl.
#
# Template variables (substituted by build.sh via envsubst):
#   BUILD_USER         ephemeral SSH user name
#   BUILD_PUBLIC_KEY   public half of the dedicated Packer keypair
#
# The build user is deleted in Packer's shutdown_command before the
# image is saved. It will NOT be present in any VM cloned from the
# golden image.

groups:
  - ssh-users

users:
  - name: ${BUILD_USER}
    groups: [wheel, ssh-users]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${BUILD_PUBLIC_KEY}

disable_root: true

# Grow partition and filesystem to fill the disk Packer resized with
# disk_size. Without this the provisioners run on a ~10 GB root (the
# GenericCloud default) even though the disk is 20 GB.
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
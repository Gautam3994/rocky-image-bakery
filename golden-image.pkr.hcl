packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ─────────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────────

variable "source_image" {
  type        = string
  description = "Path or URL to the Rocky 10 GenericCloud qcow2 base image."
  default     = "Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "source_checksum" {
  type        = string
  description = "sha256:<hash> for source_image. Use 'none' only in dev."
  default     = "none"
}

variable "output_dir" {
  type    = string
  default = "output-golden"
}

variable "vm_name" {
  type    = string
  default = "rocky10-golden.qcow2"
}

variable "disk_size" {
  type        = number
  description = "Disk size in MB. Packer resizes source qcow2 to this; cloud-init growpart fills the partition."
  default     = 20480 # 20 GB
}

variable "memory" {
  type    = number
  default = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

variable "build_user" {
  type        = string
  description = "Ephemeral SSH user for the Packer communicator. Removed in shutdown_command."
  default     = "packer"
}

variable "build_private_key_file" {
  type        = string
  description = "Path to the private key matching the public key embedded in nocloud/user-data. Injected by build.sh."
}

variable "loki_host" {
  type        = string
  description = "Hostname/IP of the Loki instance. Replaces __LOKI_HOST__ in fluent-bit.conf at build time."
  default     = "loki.lab.local"
}
# ─────────────────────────────────────────────────────────────────
# Source
# ─────────────────────────────────────────────────────────────────

source "qemu" "rocky10_golden" {
  # ── Base image ────────────────────────────────────────────────
  iso_url      = var.source_image
  iso_checksum = var.source_checksum
  disk_image   = true # source is a bootable qcow2, not an ISO

  # ── Output ────────────────────────────────────────────────────
  format           = "qcow2"
  disk_interface   = "virtio"
  output_directory = var.output_dir
  vm_name          = var.vm_name
  # Packer resizes the copied source image to disk_size MB.
  # cloud-init growpart + resize_rootfs in nocloud/user-data.tpl
  # fills the partition on first boot so provisioners don't run out
  # of space.
  # NOTE: output image retains a backing-file chain to source_image.
  # Flatten before distributing:
  #   qemu-img convert -O qcow2 -c output-golden/rocky10-golden.qcow2 flat.qcow2
  disk_size = var.disk_size

  # ── VM resources ──────────────────────────────────────────────
  memory      = var.memory
  cpus        = var.cpus
  accelerator = "kvm"
  headless    = true
  net_device  = "virtio-net"

  # ── Cloud-init NoCloud seed ────────────────────────────────────
  # Only creates the ephemeral build user + expands the root fs.
  # build.sh (envsubst) renders user-data.tpl → user-data before
  # this runs, embedding the build public key.
  cd_files = [
    "${path.root}/nocloud/meta-data",
    "${path.root}/nocloud/user-data",
  ]
  cd_label = "cidata"

  # ── SSH communicator ───────────────────────────────────────────
  communicator         = "ssh"
  ssh_username         = var.build_user
  ssh_private_key_file = var.build_private_key_file
  ssh_timeout          = "10m"

  # ── Boot ──────────────────────────────────────────────────────
  # GenericCloud images boot directly; no boot_command needed.
  # 20 s gives QEMU time to start before we begin polling SSH.
  boot_wait = "20s"

  qemuargs = [
    ["-machine", "type=q35,accel=kvm"],
    ["-cpu", "host"],
  ]

  # ── Shutdown ───────────────────────────────────────────────────
  # 1. Reset cloud-init state so per-instance user-data runs fresh
  #    on every VM cloned from this image.
  # 2. Remove the ephemeral build user (fails-fast if already gone).
  # 3. Power off.
  shutdown_command = join(" && ", [
      "sudo cloud-init clean --logs",
      "sudo userdel -rf ${var.build_user}",
      "sudo rm -f /etc/ssh/ssh_host_*",        # Scrub SSH host keys
      "sudo truncate -s 0 /etc/machine-id",    # Clear machine-id (systemd will regenerate)
      "sudo dnf clean all",                    # Save disk space
      "sudo shutdown -P now"
  ])
  shutdown_timeout = "5m"
}

# ─────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────

build {
  name    = "rocky10-golden"
  sources = ["source.qemu.rocky10_golden"]

  # ── 0: Wait for build-time cloud-init ─────────────────────────
  # The NoCloud seed only creates the build user; block until it
  # finishes so the system is stable before provisioners touch it.
  provisioner "shell" {
    inline = [
      "sudo cloud-init status --wait",
      "echo 'cloud-init seed complete'",
    ]
  }

  # ── 1: System update ──────────────────────────────────────────
  # Always reboot after update so the running kernel matches the
  # installed packages. expect_disconnect tells Packer to wait for
  # SSH to reconnect instead of treating the drop as a failure.
  provisioner "shell" {
    inline            = ["sudo dnf -y update && sudo reboot"]
    expect_disconnect = true
    timeout           = "20m"
  }

  provisioner "shell" {
    inline       = ["echo 'back after post-update reboot'"]
    pause_before = "30s" # let the VM settle before next step
  }

  # ── 2: Repos ──────────────────────────────────────────────────
  # Upload the Fluent Bit repo file before enabling EPEL so dnf
  # makecache can pull all three at once.
  provisioner "file" {
    source      = "${path.root}/files/fluent-bit.repo"
    destination = "/tmp/fluent-bit.repo"
  }

  provisioner "shell" {
    inline = [
      "sudo dnf install -y epel-release",
      "sudo install -m 644 /tmp/fluent-bit.repo /etc/yum.repos.d/fluent-bit.repo",
      # $releasever resolves to 10 on Rocky 10. If the build 404s here,
      # the rockylinux/10 path hasn't been published yet on
      # packages.fluentbit.io; fall back to rockylinux/9 or use their
      # install script.
      "sudo dnf makecache",
    ]
  }

  # ── 3: Packages ───────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo dnf install -y qemu-guest-agent tcpdump numactl sysstat iperf3 firewalld ipset fluent-bit",
      # fail2ban and python3-systemd live in EPEL, which is now enabled.
      "sudo dnf install -y fail2ban python3-systemd",
    ]
    timeout = "15m"
  }

  # ── 4: Config files ───────────────────────────────────────────
  # Upload all static config files in one provisioner, then move
  # them into place with sudo.
  provisioner "file" {
    sources = [
      "${path.root}/files/sshd-hardening.conf",
      "${path.root}/files/ssh-banner.txt",
      "${path.root}/files/sysctl-hardening.conf",
      "${path.root}/files/fail2ban-jail.local",
      "${path.root}/files/fluent-bit.conf",
    ]
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 644 /tmp/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf",
      "sudo install -m 644 /tmp/ssh-banner.txt       /etc/ssh/banner.txt",
      "sudo install -m 644 /tmp/sysctl-hardening.conf /etc/sysctl.d/99-hardening.conf",
      "sudo install -m 644 /tmp/fail2ban-jail.local  /etc/fail2ban/jail.local",
      # Substitute Loki host placeholder before the file goes into place.
      # instance=unset is intentional: per-instance cloud-init patches it.
      "sudo sed -i 's|__LOKI_HOST__|${var.loki_host}|g' /tmp/fluent-bit.conf",
      "sudo install -m 644 /tmp/fluent-bit.conf      /etc/fluent-bit/fluent-bit.conf",
    ]
  }

  # ── 5: Services, firewall, sysctl ─────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo systemctl enable --now qemu-guest-agent",
      "sudo systemctl enable --now firewalld",
      "sudo systemctl enable --now fail2ban",
      "sudo systemctl enable --now chronyd",
      # Validate new sshd drop-in, then reload (reload != restart;
      # existing Packer SSH session survives).
      "sudo sshd -t",
      "sudo systemctl reload sshd",
      "sudo firewall-cmd --permanent --add-service=ssh",
      "sudo firewall-cmd --reload",
      "sudo firewall-cmd --query-service=ssh",
      "sudo sysctl --system",
      # fluent-bit is intentionally NOT started here.
      # Its config still has instance=unset; per-instance cloud-init
      # patches that label and starts the service on first clone boot.
    ]
  }

  # ── 6: Validation gate ────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo systemctl is-active --quiet qemu-guest-agent || { echo 'FAIL qemu-guest-agent'; exit 1; }",
      "sudo systemctl is-active --quiet firewalld        || { echo 'FAIL firewalld';        exit 1; }",
      "sudo systemctl is-active --quiet fail2ban         || { echo 'FAIL fail2ban';         exit 1; }",
      "sudo systemctl is-active --quiet sshd             || { echo 'FAIL sshd';             exit 1; }",
      "sudo systemctl is-active --quiet chronyd          || { echo 'FAIL chronyd';          exit 1; }",
      "sudo sshd -t                                      || { echo 'FAIL sshd config';      exit 1; }",
      "echo 'All validation checks passed'",
    ]
  }

  # Optional: generate a SHA256 checksum alongside the image.
  # Uncomment to enable.
  # post-processor "checksum" {
  #   checksum_types = ["sha256"]
  #   output         = "${var.output_dir}/{{.ChecksumType}}.checksum"
  # }
}
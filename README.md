# Rocky 10 Golden Image Pipeline

An automated, test-driven pipeline for building hardened, immutable Rocky Linux 10 base images using Packer and QEMU.

This repository defines the foundational compute layer for a production-grade infrastructure ecosystem. It is specifically optimized to serve as a secure, observable base for Kubernetes nodes and high-throughput Spring Boot microservices, ensuring that every piece of compute boots with a standardized security posture and telemetry stack.

## 🏗️ Architecture & Engineering Principles

This project abandons the "pet server" model in favor of strict immutable infrastructure. The architecture is driven by four core principles:

### 1. Strict State Separation (Build-Time vs. Run-Time)

A common anti-pattern is relying heavily on `cloud-init` at boot to install packages and configure the OS, leading to slow start times and fragile boots if external repositories are down.

* **Build-Time (Packer):** Handles heavy lifting. Packages are installed, SELinux contexts are restored, kernel parameters (`sysctl`) are tuned, and the SSH daemon is hardened.
* **Run-Time (`instance-cloud-init.yml`):** Strictly limited to instance-specific state—injecting SSH keys, expanding the root filesystem, and labeling the telemetry agent with the dynamic hostname.

### 2. Shift-Left Infrastructure Validation

Infrastructure as Code (IaC) is incomplete without tests. This pipeline treats infrastructure exactly like application software by enforcing a formal validation gate.

* **Goss Integration:** Before the image is finalized, a localized Goss test suite runs directly inside the ephemeral VM. It asserts that required services (`sshd`, `fail2ban`) are running, specific ports are listening, and critical file permissions are enforced. If the image isn't compliant, the build fails before it can be distributed.

### 3. Defense in Depth (Hardening)

The image is secured by default, assuming an adversarial network environment.

* **Kernel & Network:** IP forwarding is enabled for KVM/container routing, while strict protections against SYN floods and martian packets are enforced via `sysctl`.
* **Access Control:** SSH is heavily restricted (no root login, disabled DNS, strictly limited to the `ssh-users` group) and monitored by `fail2ban`.
* **Ephemeral Build Hygiene:** The dedicated `packer` build user, along with all SSH host keys and `machine-id` data, are aggressively scrubbed during the shutdown sequence to prevent leaked credentials or state collision across cloned instances.

### 4. Resilient Telemetry (Observability)

Logs are critical during node failure, but network partitions can drop telemetry data.

* **Fluent Bit with File Buffering:** Fluent Bit is baked in and pre-configured to ship `systemd` and `sshd` logs to a centralized Loki cluster. Crucially, it utilizes a filesystem-backed buffer (`storage.type filesystem`). If the Loki endpoint becomes unreachable, Fluent Bit queues the logs locally without overwhelming memory, ensuring zero data loss during network partitions.

## 🚀 Usage

### Prerequisites

* `packer` (v1.9.0+)
* `qemu-system-x86_64` (with KVM support enabled)
* `envsubst`

### Building the Image

The build process relies on an injection script to safely handle ephemeral SSH keys without committing them to version control.

```bash
# 1. Generate an ephemeral keypair for the Packer communicator
ssh-keygen -t ed25519 -f packer-key -N ""

# 2. Export required environment variables
export BUILD_PUBLIC_KEY="$(cat packer-key.pub)"
export BUILD_PRIVATE_KEY_FILE="$(pwd)/packer-key"

# 3. Trigger the build
./build.sh -var-file=example.pkrvars.hcl

```

### Cloning and Booting

When deploying a VM from the resulting `.qcow2` image, attach a NoCloud ISO (or metadata service) containing the `instance-cloud-init.yml`. The instance will dynamically resize its disk, patch its telemetry configuration, and run a final service health gate before signaling readiness.

---
# example.pkrvars.hcl — copy to prod.pkrvars.hcl and adjust.
#
# build_user and build_private_key_file are injected by build.sh
# via -var flags; don't put them here.

source_image    = "Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
source_checksum = "none" # replace with sha256:<hash> before any prod build
output_dir      = "output-golden"
vm_name         = "rocky10-golden.qcow2"
disk_size       = 20480 # MB → 20 GB
memory          = 2048
cpus            = 2
loki_host       = "loki.lab.local"
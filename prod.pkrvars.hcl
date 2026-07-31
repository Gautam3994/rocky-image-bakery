# example.pkrvars.hcl — copy to prod.pkrvars.hcl and adjust.
#
# build_user and build_private_key_file are injected by build.sh
# via -var flags; don't put them here.

source_image    = "/var/lib/libvirt/images/rocky-10-base.qcow2"
source_checksum = "sha256:c79d8d6bc227466f3b931dc8db4859e9f5316106fefe2b5dd0ab5141fcf4991e"  
output_dir      = "output-golden"
vm_name_prefix  = "rocky10-golden"
disk_size       = 20480 # MB → 20 GB
memory          = 2048
cpus            = 2
loki_host       = "loki.lab.local"
build_user      = "packer"
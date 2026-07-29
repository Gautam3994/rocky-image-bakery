#!/usr/bin/env bash
# build.sh — renders nocloud/user-data.tpl then invokes packer build.
#
# Packer's cd_files takes file paths, not rendered strings, so the
# user-data template (which needs the build public key) must be
# written to disk before `packer build` runs. This script does that.
#
# Required env vars:
#   BUILD_PUBLIC_KEY        public half of the dedicated Packer keypair
#   BUILD_PRIVATE_KEY_FILE  path to the private half
#
# Optional env vars:
#   BUILD_USER   (default: packer)
#   LOKI_HOST    (default: loki.lab.local)
#
# All remaining args are forwarded to packer build, e.g.:
#   ./build.sh -var-file=prod.pkrvars.hcl
#   ./build.sh -var source_image=/mnt/images/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2
#   ./build.sh -on-error=ask     # drop into debugger on failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BUILD_USER:=packer}"
: "${BUILD_PUBLIC_KEY:?BUILD_PUBLIC_KEY must be set}"
: "${BUILD_PRIVATE_KEY_FILE:?BUILD_PRIVATE_KEY_FILE must be set}"
: "${LOKI_HOST:=loki.lab.local}"

# Render the build-time NoCloud user-data.
# envsubst with an explicit variable list so $releasever and other
# shell variables in the template are NOT expanded here.
# SC2016 is intentional: envsubst expects a literal variable list.
# shellcheck disable=SC2016
envsubst '${BUILD_USER} ${BUILD_PUBLIC_KEY}' \
  < "${SCRIPT_DIR}/nocloud/user-data.tpl" \
  > "${SCRIPT_DIR}/nocloud/user-data"

echo "[build.sh] rendered nocloud/user-data for build user '${BUILD_USER}'"

exec packer build \
  -var "build_user=${BUILD_USER}" \
  -var "build_private_key_file=${BUILD_PRIVATE_KEY_FILE}" \
  -var "loki_host=${LOKI_HOST}" \
  "${@}" \
  "${SCRIPT_DIR}"
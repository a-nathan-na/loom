#!/usr/bin/env bash
# Download and verify the prebuilt ONNX Runtime distribution into third_party/.
#
# We use the upstream prebuilt tarball rather than building from source: an ORT
# source build takes hours and would consume a large fraction of this project's
# total time budget for zero added signal.
#
# Usage:
#   ./scripts/fetch_onnxruntime.sh              # fetch the pinned version
#   LOOM_ORT_VERSION=1.21.0 ./scripts/...       # fetch a different version
#   ./scripts/fetch_onnxruntime.sh --print-sha  # print the SHA256 to pin

set -euo pipefail

VERSION="${LOOM_ORT_VERSION:-1.20.1}"

# SHA256 of onnxruntime-linux-x64-${VERSION}.tgz. Empty means "unpinned": the
# script will still work but will warn, and print the SHA it saw so you can pin
# it here. Never leave this empty on a branch you intend to merge.
declare -A ORT_SHA256=(
  ["1.20.1"]="67db4dc1561f1e3fd42e619575c82c601ef89849afc7ea85a003abbac1a1a105"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/third_party"
NAME="onnxruntime-linux-x64-${VERSION}"
TARBALL="${NAME}.tgz"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${VERSION}/${TARBALL}"

print_sha_only=0
[[ "${1:-}" == "--print-sha" ]] && print_sha_only=1

if [[ -d "${DEST_DIR}/${NAME}" && "${print_sha_only}" -eq 0 ]]; then
  echo "ONNX Runtime ${VERSION} already present at ${DEST_DIR}/${NAME}"
  exit 0
fi

mkdir -p "${DEST_DIR}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Downloading ${URL}"
curl -fSL --retry 3 --retry-delay 2 -o "${tmp}/${TARBALL}" "${URL}"

actual="$(sha256sum "${tmp}/${TARBALL}" | cut -d' ' -f1)"
expected="${ORT_SHA256[${VERSION}]:-}"

if [[ "${print_sha_only}" -eq 1 ]]; then
  echo "${VERSION} ${actual}"
  exit 0
fi

if [[ -z "${expected}" ]]; then
  echo "WARNING: no SHA256 pinned for ONNX Runtime ${VERSION}." >&2
  echo "         Downloaded artifact hashes to:" >&2
  echo "           ${actual}" >&2
  echo "         Add it to ORT_SHA256 in $(basename "${BASH_SOURCE[0]}") to pin." >&2
elif [[ "${expected}" != "${actual}" ]]; then
  echo "ERROR: SHA256 mismatch for ${TARBALL}" >&2
  echo "  expected ${expected}" >&2
  echo "  actual   ${actual}" >&2
  exit 1
else
  echo "SHA256 verified: ${actual}"
fi

echo "Extracting to ${DEST_DIR}/${NAME}"
tar -xzf "${tmp}/${TARBALL}" -C "${DEST_DIR}"

test -f "${DEST_DIR}/${NAME}/include/onnxruntime_cxx_api.h" \
  || { echo "ERROR: extracted tree missing onnxruntime_cxx_api.h" >&2; exit 1; }

echo "ONNX Runtime ${VERSION} ready at ${DEST_DIR}/${NAME}"

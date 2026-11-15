#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Saves the candidate under the published name for the share action, which documents every
# variable read here. A later job loads it and finds its own pin already present.

set -eu

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set. This runs under GitHub Actions.}"

candidate="${CANDIDATE:?CANDIDATE names the image resolve.sh built.}"
published="${PUBLISHED:?PUBLISHED names the image the pin points at.}"
artifact="${ARTIFACT:?The artifact input names the artifact to upload.}"

dir="${RUNNER_TEMP:-/tmp}/dev-image-share"
rm -rf "${dir}"
mkdir -p "${dir}"

if command -v zstd >/dev/null 2>&1; then
  archive="${dir}/image.tar.zst"
  set -- zstd -q -T0
else
  archive="${dir}/image.tar.gz"
  set -- gzip -1
fi

# Put the tag back afterwards. A daemon other jobs share must keep the pin on what it held.
previous="$(docker image inspect --format '{{.Id}}' "${published}" 2>/dev/null || :)"
docker tag "${candidate}" "${published}"

# POSIX sh has no pipefail, so the status of docker save has to come back through a file.
status="${dir}/save-status"
{ docker save "${published}" || echo "$?" >"${status}"; } | "$@" >"${archive}"

if [ -n "${previous}" ]; then
  docker tag "${previous}" "${published}"
else
  docker rmi "${published}" >/dev/null
fi

if [ -s "${status}" ]; then
  code="$(cat "${status}")"
  echo "docker save ${published} exited ${code}." >&2
  exit 1
fi
rm -f "${status}"

size="$(du -h "${archive}" | cut -f 1)"
echo "Saved ${candidate} as ${published} to ${archive}, ${size}, for the ${artifact} artifact" >&2

{
  echo "path=${archive}"
  echo "artifact=${artifact}"
} >>"${GITHUB_OUTPUT}"

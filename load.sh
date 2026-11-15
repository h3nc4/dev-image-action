#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Loads the image a share job saved from ARCHIVE_DIR, where the root action downloaded it,
# then deletes the archive to free the disk. docker load reads gzip and zstd by itself.

set -eu

dir="${ARCHIVE_DIR:?ARCHIVE_DIR is where the artifact was downloaded.}"

loaded=""
for archive in "${dir}"/image.tar*; do
  [ -f "${archive}" ] || continue
  docker load -q -i "${archive}" >&2
  loaded="${archive}"
done

if [ -z "${loaded}" ]; then
  echo "The artifact holds no image.tar archive. It has to come from the share action." >&2
  exit 1
fi

rm -rf "${dir}"

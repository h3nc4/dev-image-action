#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Names the image a CI job should run in, and exports the docker invocation its steps use.
# A change touching the image inputs is built from the checkout, so the job exercises the
# candidate rather than the published image it is about to replace. Nothing is pushed: the
# image stays in this runner's daemon, which is why callers reach it through docker run
# rather than a container job, and why every job resolves this for itself.
#
# Called by the actions in this repository, which document every variable read here. Writes
# image, published and built to GITHUB_OUTPUT, and DEV_IMAGE and DEV_RUN to GITHUB_ENV.

set -eu

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set. This runs under GitHub Actions.}"
: "${GITHUB_ENV:?GITHUB_ENV is not set. This runs under GitHub Actions.}"

cd "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set. This runs under GitHub Actions.}"

workdir="${WORKDIR:-/workspace}"
dockerfile="${DOCKERFILE:-docker/dev.Dockerfile}"
devcontainer_file="${DEVCONTAINER_FILE:-.devcontainer.json}"
image_inputs="${IMAGE_INPUTS:-docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh}"

published="${IMAGE:-}"
origin="the image input"
if [ -z "${published}" ]; then
  origin="the image key in ${devcontainer_file}"
  if [ ! -f "${devcontainer_file}" ]; then
    echo "${devcontainer_file} is not there. Point devcontainer-file at the dev container" \
      "definition, or name the image outright with the image input." >&2
    exit 1
  fi
  # The first "image" key, which in a dev container definition is the top-level one. A key
  # behind a // comment does not open its line, so a commented-out image is passed over.
  published="$(
    sed -n 's/^[[:space:]]*"image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${devcontainer_file}" | head -n 1
  )"
  if [ -z "${published}" ]; then
    echo "${devcontainer_file} has no image key, so it either builds its own image or names" \
      "one somewhere this cannot read. Name it with the image input." >&2
    exit 1
  fi
fi

# A reference with no tag pulls whatever latest happens to be, which is the opposite of a pin.
# The colon has to sit in the last path element, since an earlier one is a registry's port.
case "${published##*/}" in
  *:?*) ;;
  *)
    echo "${origin} is '${published}', which carries no tag." \
      "Pin the version the job should run, such as '${published}:1'." >&2
    exit 1
    ;;
esac
published_repo="${published%:*}"

# An image loaded from a share job was already decided there, so diffing again could only
# rebuild what that job built.
if [ -n "${SHARED:-}" ]; then
  echo "Image shared through the ${SHARED} artifact, so the image inputs are not compared" >&2
  BASE_SHA=""
fi

# A first push to a branch reports an all-zero base and has nothing to compare against, so
# treat the image as untouched. A base that no longer resolves, after a force-push, is the
# opposite case: nothing can be ruled out, so build.
changed=""
case "${BASE_SHA:-}" in
  "" | 0000000000000000000000000000000000000000) ;;
  *)
    if git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
      # image_inputs is a space-separated list of paths, so it is split on purpose.
      # shellcheck disable=SC2086
      set -- ${image_inputs}
      changed="$(git diff --name-only "${BASE_SHA}" HEAD -- "$@")"
    else
      changed="(base ${BASE_SHA} unreachable)"
    fi
    ;;
esac

image=""
built="false"
if [ -z "${changed}" ]; then
  # A tag already in the daemon came from an earlier pull or a docker load. One loaded from a
  # share job exists in no registry, so pulling it would fail.
  if docker image inspect "${published}" >/dev/null 2>&1; then
    image="${published}"
    echo "Image inputs untouched and ${image} is already present, so using it without a pull" >&2
  elif [ -n "${SHARED:-}" ]; then
    echo "::warning::The ${SHARED} artifact did not hold ${published}, so it is being pulled." \
      "Pass the share job's image output as the image input."
  fi
fi
# A share job passes the pin on without running it. For that job a manifest lookup proves the
# tag exists, and a failed lookup falls back to the pull.
present="true"
if [ -z "${changed}" ] && [ -z "${image}" ] && [ "${PULL:-true}" = "false" ]; then
  if docker buildx imagetools inspect "${published}" >/dev/null 2>&1 ||
    docker manifest inspect "${published}" >/dev/null 2>&1; then
    image="${published}"
    present="false"
    echo "Image inputs untouched and ${image} is published, so it is left unpulled" >&2
  fi
fi
if [ -z "${changed}" ] && [ -z "${image}" ]; then
  if docker pull -q "${published}" >/dev/null 2>&1; then
    image="${published}"
    echo "Image inputs untouched, so using ${image}" >&2
  else
    changed="${published} could not be pulled"
    echo "::warning::${changed}, so it is being built from this checkout instead." \
      "Otherwise check ${origin}, and whether this job logs in to the registry."
  fi
fi

if [ -z "${image}" ]; then
  # No namespace, so nothing tries to pull this from a registry.
  image="${published_repo##*/}:candidate"
  echo "Building ${image} from this checkout:" >&2
  echo "${changed}" | sed 's/^/  /' >&2
  set -- build
  if [ -n "${CACHE_FROM:-}" ] || [ -n "${CACHE_TO:-}" ]; then
    set -- buildx build --load
    if [ -n "${CACHE_FROM:-}" ]; then set -- "$@" --cache-from "${CACHE_FROM}"; fi
    if [ -n "${CACHE_TO:-}" ]; then set -- "$@" --cache-to "${CACHE_TO}"; fi
  fi
  docker "$@" -f "${dockerfile}" -t "${image}" .
  built="true"
fi

uid="$(id -u)"
gid="$(id -g)"

# Probing for bash runs the image, so DEV_RUN probes an unpulled one on its first use instead.
if [ "${present}" = "true" ]; then
  entrypoint="/bin/sh"
  if docker run --rm --entrypoint /bin/bash "${image}" -c ':' >/dev/null 2>&1; then
    entrypoint="/bin/bash"
  fi
  echo "Running commands through ${entrypoint}" >&2
else
  entrypoint="\"\${entrypoint}\""
  echo "Running commands through bash if ${image} has it, else /bin/sh" >&2
fi

case "${PWD}" in
  *"'"*)
    echo "The checkout path contains a single quote, which cannot be quoted here." >&2
    exit 1
    ;;
  *) ;;
esac

runner="${RUNNER_TEMP:-/tmp}/dev-run"
{
  echo '#!/bin/sh'
  echo '# Generated by h3nc4/dev-image-action. Runs one command in the dev image.'
  if [ "${present}" = "false" ]; then
    echo 'entrypoint=/bin/sh'
    printf "if docker run --rm --entrypoint /bin/bash '%s' -c ':' >/dev/null 2>&1; then\n" "${image}"
    echo '  entrypoint=/bin/bash'
    echo 'fi'
  fi
  printf 'exec docker run --rm --user %s:%s --entrypoint %s' "${uid}" "${gid}" "${entrypoint}"
  printf " -v '%s':'%s' -e HOME=/tmp -w '%s'" "${PWD}" "${workdir}" "${workdir}"
  if [ -n "${DOCKER_ARGS:-}" ]; then
    printf ' %s' "${DOCKER_ARGS}"
  fi
  printf " '%s' \"\$@\"\n" "${image}"
} >"${runner}"
chmod +x "${runner}"

{
  echo "image=${image}"
  echo "published=${published}"
  echo "built=${built}"
} >>"${GITHUB_OUTPUT}"
{
  echo "DEV_IMAGE=${image}"
  echo "DEV_RUN=${runner}"
} >>"${GITHUB_ENV}"

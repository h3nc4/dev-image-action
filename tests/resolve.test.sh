#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Exercises resolve.sh against a throwaway repository, covering both decisions it makes and
# proving the invocation it exports actually runs. Needs docker and git.

set -eu

here="$(dirname "$0")"
root="$(cd "${here}/.." && pwd)"
resolve="${root}/resolve.sh"
published="busybox"
tag="musl"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT INT TERM
repo="${work}/repo"

failures=0

check() { # $1=label $2=expected, rest: command producing the actual value
  label="$1"
  expected="$2"
  shift 2
  if actual="$("$@")"; then
    if [ "${expected}" = "${actual}" ]; then
      printf '  ok    %s\n' "${label}"
      return 0
    fi
    printf '  FAIL  %s\n          expected %s\n          got      %s\n' \
      "${label}" "${expected}" "${actual}"
  else
    printf '  ERROR %s\n          command exited %s\n' "${label}" "$?"
  fi
  failures=$((failures + 1))
}

mkdir -p "${repo}/docker" "${repo}/scripts" "${repo}/.github"
cd "${repo}"
git init -q -b main
git config user.email ci@example.com
git config user.name CI
git config commit.gpgsign false
printf '%s\n' "${tag}" >.github/VERSION
printf 'FROM %s:%s\n' "${published}" "${tag}" >docker/dev.Dockerfile
printf '#!/bin/sh\n' >scripts/entrypoint.sh
printf '#!/bin/sh\n' >scripts/switch-user.sh
printf 'unrelated\n' >README.md
git add -A
git commit -qm "base"
base="$(git rev-parse HEAD)"

resolved() { # $1=BASE_SHA, rest: VAR=value overrides
  base_sha="$1"
  shift
  : >"${work}/out"
  : >"${work}/env"
  env - PATH="${PATH}" HOME="${HOME}" \
    GITHUB_WORKSPACE="${repo}" \
    GITHUB_OUTPUT="${work}/out" \
    GITHUB_ENV="${work}/env" \
    RUNNER_TEMP="${work}" \
    PUBLISHED_REPO="${published}" \
    BASE_SHA="${base_sha}" \
    "$@" \
    sh "${resolve}" >"${work}/log" 2>&1 || {
    echo "resolve.sh failed:" >&2
    sed 's/^/    /' "${work}/log" >&2
    return 1
  }
  sed -n 's/^image=//p' "${work}/out"
}

exported() { # echoes one variable from the last resolve
  sed -n "s/^$1=//p" "${work}/env"
}

chosen_entrypoint() { # reads it back off the script the last resolve generated
  script="$(exported DEV_RUN)"
  sed -n 's/.*--entrypoint \([^ ]*\).*/\1/p' "${script}"
}

with_version() { # $1=contents of the version file for this one call
  printf '%s\n' "$1" >.github/VERSION
  resolved "${base}"
  printf '%s\n' "${tag}" >.github/VERSION
}

echo "Deciding which image to use"
check "untouched inputs use the published image" "${published}:${tag}" \
  resolved "${base}"
check "an all-zero base is not a change" "${published}:${tag}" \
  resolved 0000000000000000000000000000000000000000
check "an absent base is not a change" "${published}:${tag}" \
  resolved ""
check "the version file supplies the tag" "${published}:glibc" \
  with_version glibc
printf '%s\n' "${tag}" >build-id
check "an alternative version file is read" "${published}:${tag}" \
  resolved "${base}" VERSION_FILE=build-id
rm -f build-id

echo "Rebuilding when the inputs move"
printf 'FROM %s:%s\nRUN true\n' "${published}" "${tag}" >docker/dev.Dockerfile
git commit -qam "touch the dockerfile"
check "a changed dockerfile builds a candidate" "${published}:candidate" \
  resolved "${base}"
check "an unreachable base builds a candidate" "${published}:candidate" \
  resolved deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
check "a path outside image-inputs is ignored" "${published}:${tag}" \
  resolved "${base}" IMAGE_INPUTS=scripts/entrypoint.sh
printf 'changed\n' >scripts/switch-user.sh
git commit -qam "touch a copied script"
check "any listed input counts, not just the dockerfile" "${published}:candidate" \
  resolved "${base}"

echo "Bootstrapping, and recovering from a tag that is not there"
head_sha="$(git rev-parse HEAD)"
check "an unpullable published image builds instead" "nonexistent-dev-xyz:candidate" \
  resolved "${head_sha}" PUBLISHED_REPO=h3nc4/nonexistent-dev-xyz

echo "The exported invocation"
image="$(resolved "${base}")"
run="$(exported DEV_RUN)"
me="$(id -u)"
check "DEV_IMAGE matches the resolved image" "${image}" \
  exported DEV_IMAGE
check "it runs a command in the image" "hello" \
  sh "${run}" -c 'echo hello'
check "the checkout is mounted at the workdir" "unrelated" \
  sh "${run}" -c 'cat /workspace/README.md'
check "the container user is not root" "${me}" \
  sh "${run}" -c 'id -u'

resolved "${base}" WORKDIR=/src >/dev/null
run="$(exported DEV_RUN)"
check "workdir is configurable" "unrelated" \
  sh "${run}" -c 'cat /src/README.md'

resolved "${base}" >/dev/null
check "an image without bash falls back to /bin/sh" "/bin/sh" \
  chosen_entrypoint

printf 'FROM bash:5.3-alpine3.22\nRUN ln -s /usr/local/bin/bash /bin/bash\n' \
  >docker/bash.Dockerfile
git add -A
git commit -qm "a fixture image carrying bash"
resolved "${base}" DOCKERFILE=docker/bash.Dockerfile IMAGE_INPUTS=docker/bash.Dockerfile \
  >/dev/null
check "an image with bash is preferred over sh" "/bin/bash" \
  chosen_entrypoint

resolved "${base}" DOCKER_ARGS="-e EXTRA=passed" >/dev/null
run="$(exported DEV_RUN)"
# EXTRA is set by the flag under test, so it has to reach the container's shell unexpanded.
# shellcheck disable=SC2016
check "docker-args reach the container" "passed" \
  sh "${run}" -c 'printf %s "${EXTRA}"'

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"

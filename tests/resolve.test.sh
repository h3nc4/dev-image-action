#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Exercises resolve.sh against a throwaway repository, covering both decisions it makes and
# proving the invocation it exports actually runs. Also hands a candidate between two jobs
# through share.sh and load.sh, and deletes it with cleanup.sh against a stand-in API. Needs
# docker and git, and jq or node for the cleanup.

set -eu

here="$(dirname "$0")"
root="$(cd "${here}/.." && pwd)"
resolve="${root}/resolve.sh"
published="busybox"
tag="musl"
# Names only this suite creates, so removing them afterwards touches nothing else.
local_only="dev-image-action-test/local-only:1"
shared="dev-image-action-test/shared:1"

work="$(mktemp -d)"
cleanup() {
  docker rmi "${local_only}" "${shared}" local-only:candidate >/dev/null 2>&1 || :
  rm -rf "${work}"
}
trap cleanup EXIT INT TERM
repo="${work}/repo"

failures=0

pin() { # $1=file, $2=image reference: writes a dev container definition pinning it
  printf '{\n  "name": "fixture",\n  "image": "%s"\n}\n' "$2" >"$1"
}

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

mkdir -p "${repo}/docker" "${repo}/scripts"
cd "${repo}"
git init -q -b main
git config user.email ci@example.com
git config user.name CI
git config commit.gpgsign false
pin .devcontainer.json "${published}:${tag}"
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
    BASE_SHA="${base_sha}" \
    "$@" \
    sh "${resolve}" >"${work}/log" 2>&1 || {
    echo "resolve.sh failed:" >&2
    sed 's/^/    /' "${work}/log" >&2
    return 1
  }
  sed -n 's/^image=//p' "${work}/out"
}

output() { # echoes one output from the last resolve
  sed -n "s/^$1=//p" "${work}/out"
}

exported() { # echoes one variable from the last resolve
  sed -n "s/^$1=//p" "${work}/env"
}

chosen_entrypoint() { # reads it back off the script the last resolve generated
  script="$(exported DEV_RUN)"
  sed -n 's/.*--entrypoint \([^ ]*\).*/\1/p' "${script}"
}

refused() { # $1=label $2=fragment the message has to carry, rest: VAR=value overrides
  label="$1"
  needle="$2"
  shift 2
  status=0
  # Refusing is the assertion here, so set -e is meant to stand aside for it.
  # shellcheck disable=SC2310
  resolved "${base}" "$@" >/dev/null 2>&1 || status=$?
  if [ "${status}" -eq 0 ]; then
    printf '  FAIL  %s\n          it resolved an image instead of refusing\n' "${label}"
  elif grep -qF "${needle}" "${work}/log"; then
    printf '  ok    %s\n' "${label}"
    return 0
  else
    printf '  FAIL  %s\n          no mention of "%s" in:\n' "${label}" "${needle}"
    sed 's/^/          /' "${work}/log"
  fi
  failures=$((failures + 1))
}

echo "Deciding which image to use"
check "untouched inputs use the pinned image" "${published}:${tag}" \
  resolved "${base}"
check "an all-zero base is not a change" "${published}:${tag}" \
  resolved 0000000000000000000000000000000000000000
check "an absent base is not a change" "${published}:${tag}" \
  resolved ""

docker tag "${published}:${tag}" "${local_only}"
check "a locally present image is used without a pull" "${local_only}" \
  resolved "${base}" IMAGE="${local_only}"
check "a pulled image is not reported as built" "false" \
  output built

echo "Reading the pin"
pin alt.json "${published}:glibc"
check "an alternative dev container file is read" "${published}:glibc" \
  resolved "${base}" DEVCONTAINER_FILE=alt.json
check "the image input overrides the file" "${published}:glibc" \
  resolved "${base}" IMAGE="${published}:glibc"
{
  printf '{\n'
  printf '  // "image": "%s:uclibc",\n' "${published}"
  printf '  "image": "%s:glibc"\n}\n' "${published}"
} >commented.json
check "a commented-out image is passed over" "${published}:glibc" \
  resolved "${base}" DEVCONTAINER_FILE=commented.json
printf '{\n  "name": "builds its own"\n}\n' >keyless.json
refused "a file with no image key is refused" "has no image key" \
  DEVCONTAINER_FILE=keyless.json
refused "a file that is not there is refused" "is not there" \
  DEVCONTAINER_FILE=absent.json
refused "a reference with no tag is refused" "carries no tag" \
  IMAGE="${published}"
refused "a registry port is no substitute for a tag" "carries no tag" \
  IMAGE="localhost:5000/${published}"
rm -f alt.json commented.json keyless.json

echo "Rebuilding when the inputs move"
printf 'FROM %s:%s\nRUN true\n' "${published}" "${tag}" >docker/dev.Dockerfile
git commit -qam "touch the dockerfile"
check "a changed dockerfile builds a candidate" "${published}:candidate" \
  resolved "${base}"
check "the candidate is reported as built" "true" \
  output built
check "the published name is reported beside the candidate" "${published}:${tag}" \
  output published
check "a changed dockerfile still builds a locally present image" "local-only:candidate" \
  resolved "${base}" IMAGE="${local_only}"
check "a shared image is used even though the inputs moved" "${local_only}" \
  resolved "${base}" IMAGE="${local_only}" SHARED=dev-image
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
  resolved "${head_sha}" IMAGE=h3nc4/nonexistent-dev-xyz:1

check "a shared artifact missing the image falls back to the usual way" \
  "nonexistent-dev-xyz:candidate" \
  resolved "${head_sha}" IMAGE=h3nc4/nonexistent-dev-xyz:1 SHARED=dev-image
check "and it warns about the mismatch" "1" \
  grep -c "did not hold" "${work}/log"

echo "Handing a candidate to another job"
shared_out="${work}/share-out"
share() { # $1=published name: runs share.sh on the candidate the last build left
  : >"${shared_out}"
  env - PATH="${PATH}" HOME="${HOME}" \
    GITHUB_OUTPUT="${shared_out}" \
    RUNNER_TEMP="${work}" \
    CANDIDATE="${published}:candidate" \
    PUBLISHED="$1" \
    ARTIFACT=dev-image \
    sh "${root}/share.sh" >"${work}/log" 2>&1 || {
    echo "share.sh failed:" >&2
    sed 's/^/    /' "${work}/log" >&2
    return 1
  }
  sed -n 's/^path=//p' "${shared_out}"
}
image_id() {
  id="$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null)" || id=""
  echo "${id:-absent}"
}
on_disk() { if [ -s "$1" ]; then echo present; else echo gone; fi; }
loads() { if ARCHIVE_DIR="$1" sh "${root}/load.sh" >/dev/null 2>&1; then echo loaded; else echo refused; fi; }

candidate_id="$(image_id "${published}:candidate")"
archive="$(share "${shared}")"
check "the archive is written" "present" \
  on_disk "${archive}"
check "the artifact output names the artifact" "dev-image" \
  sed -n 's/^artifact=//p' "${shared_out}"
check "the published name is not left behind on the sharing daemon" "absent" \
  image_id "${shared}"

check "the archive loads" "loaded" \
  loads "$(dirname "${archive}")"
check "loading the archive brings the candidate back under the published name" \
  "${candidate_id}" image_id "${shared}"
check "loading frees the disk the archive took" "gone" \
  on_disk "${archive}"
check "the loaded image resolves without a build" "${shared}" \
  resolved "${base}" IMAGE="${shared}" SHARED=dev-image
check "and it is not reported as built" "false" \
  output built
pinned_id="$(image_id "${published}:${tag}")"
share "${published}:${tag}" >/dev/null
check "a published name already present keeps its image" "${pinned_id}" \
  image_id "${published}:${tag}"
mkdir -p "${work}/empty"
check "an artifact with no archive is refused" "refused" \
  loads "${work}/empty"

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

echo "Deleting the artifact"
# A stand-in for curl answers the listing from FAKE_LIST and every delete with FAKE_DELETE,
# and records each deleted id, so cleanup.sh runs against both forges' shapes offline.
mkdir -p "${work}/bin"
cat >"${work}/bin/curl" <<'FAKE'
#!/bin/sh
out=""
method="GET"
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -X) method="$2"; shift ;;
    -H | -w | --data-urlencode) shift ;;
    http*) url="$1" ;;
    *) ;;
  esac
  shift
done
if [ "${method}" = DELETE ]; then
  echo "${url##*/}" >>"${FAKE_LOG}"
  printf '%s' "${FAKE_DELETE}"
else
  cp "${FAKE_LIST}" "${out}"
  printf 200
fi
FAKE
chmod +x "${work}/bin/curl"

cleaned() { # $1=listing file $2=delete status, rest: VAR=value overrides. Echoes deleted ids
  list="$1"
  delete="$2"
  shift 2
  : >"${work}/deleted"
  env - PATH="${work}/bin:${PATH}" HOME="${HOME}" \
    GITHUB_API_URL=https://api.example.com \
    GITHUB_REPOSITORY=owner/repo \
    GITHUB_RUN_ID=42 \
    TOKEN=fake \
    ARTIFACT=dev-image \
    FAKE_LIST="${list}" FAKE_DELETE="${delete}" FAKE_LOG="${work}/deleted" \
    "$@" \
    sh "${root}/cleanup.sh" >"${work}/log" 2>&1 || {
    echo "cleanup.sh failed:" >&2
    sed 's/^/    /' "${work}/log" >&2
    return 1
  }
  tr '\n' ' ' <"${work}/deleted" | sed 's/ $//'
}

# GitHub nests the run, with an id of its own, inside every artifact.
printf '%s' '{"total_count":2,"artifacts":[{"id":7,"name":"dev-image","workflow_run":{"id":42}},{"id":8,"name":"other","workflow_run":{"id":42}}]}' \
  >"${work}/github.json"
printf '%s' '[{"id":9,"name":"dev-image","run_id":42},{"id":10,"name":"other","run_id":42}]' \
  >"${work}/forgejo.json"
printf '%s' '[]' >"${work}/none.json"
check "a GitHub listing deletes only the named artifact" "7" \
  cleaned "${work}/github.json" 204
check "a Forgejo listing deletes only the named artifact" "9" \
  cleaned "${work}/forgejo.json" 204
check "no matching artifact deletes nothing" "" \
  cleaned "${work}/none.json" 204
check "an empty name deletes nothing" "" \
  cleaned "${work}/github.json" 204 ARTIFACT=
cleaned "${work}/github.json" 403 >/dev/null
check "a refused delete warns rather than failing" "1" \
  grep -c "^::warning::.*refused" "${work}/log"

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"

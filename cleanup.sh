#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Deletes this run's artifacts named ARTIFACT through the REST API, which GitHub and Forgejo
# share. Every failure is a warning, since the artifact expires after a day regardless.

set -eu

artifact="${ARTIFACT:-}"
if [ -z "${artifact}" ]; then
  echo "No artifact named, so there is nothing to delete" >&2
  exit 0
fi

api="${GITHUB_API_URL:?GITHUB_API_URL is not set. This runs under GitHub Actions.}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set. This runs under GitHub Actions.}"
run="${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set. This runs under GitHub Actions.}"
token="${TOKEN:?TOKEN is not set. The cleanup action passes github.token.}"

warn() {
  echo "::warning::$*, so the ${artifact} artifact is left to expire after its one-day retention"
  exit 0
}

# GitHub wraps the list in an object and Forgejo returns a bare array.
ids() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg name "${artifact}" \
      '(if type == "array" then . else .artifacts end)[] | select(.name == $name) | .id'
  elif command -v node >/dev/null 2>&1; then
    NAME="${artifact}" node -e '
      let body = "";
      process.stdin.on("data", (chunk) => { body += chunk; });
      process.stdin.on("end", () => {
        const list = JSON.parse(body);
        for (const a of Array.isArray(list) ? list : list.artifacts) {
          if (a.name === process.env.NAME) console.log(a.id);
        }
      });'
  else
    return 127
  fi
}

listing="$(mktemp)"
trap 'rm -f "${listing}"' EXIT INT TERM

status="$(
  curl -sS -G -o "${listing}" -w '%{http_code}' \
    -H "Authorization: token ${token}" -H "Accept: application/json" \
    --data-urlencode "name=${artifact}" \
    "${api}/repos/${repo}/actions/runs/${run}/artifacts" || :
)"
case "${status}" in
  200) ;;
  *) warn "Listing the artifacts of run ${run} answered HTTP ${status:-nothing}" ;;
esac

# A missing parser is the case to report, and set -e has to stand aside to see it.
# shellcheck disable=SC2310
found="$(ids <"${listing}")" || warn "Reading the artifact list needs jq or node, and found neither"
if [ -z "${found}" ]; then
  echo "Run ${run} holds no ${artifact} artifact, so there is nothing to delete" >&2
  exit 0
fi

for id in ${found}; do
  status="$(
    curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: token ${token}" \
      "${api}/repos/${repo}/actions/artifacts/${id}" || :
  )"
  case "${status}" in
    204) echo "Deleted the ${artifact} artifact, id ${id}" >&2 ;;
    403) warn "Deleting artifact ${id} was refused. A fork's pull request is always refused, and a job without actions: write is too" ;;
    *) warn "Deleting artifact ${id} answered HTTP ${status:-nothing}" ;;
  esac
done

# dev-image-action

Runs a project's CI in its own dev container image, and rebuilds that image from the branch whenever the change touches it.

A project with a dev container usually pins it, so CI pulls a published tag. That leaves a gap: a pull request editing the Dockerfile proves only that the image still builds, never that the suite passes inside it. This action makes the suite run in the edited image. It compares the change against its base, and when a path that shapes the image has moved, it builds the image from the checkout and points the job at that instead of the tag it is about to replace. Nothing is pushed.

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0
- uses: h3nc4/dev-image-action@v3
- run: $DEV_RUN -c 'gradle --no-daemon test'
```

That is the whole integration, and it takes no inputs: the image comes from the `image` key of `.devcontainer.json`, tag and all. The step exports `DEV_RUN`, a small script that runs one command inside the resolved image with the checkout mounted, so a job step stays one line whichever image it got. The command goes through bash when the image has it and through `/bin/sh` otherwise.

## One source of truth for the image

The dev container file already decides which image an editor opens the project in, and it is the file a release has to bump for the next person who reopens the project. Reading it here is what keeps CI on that same image. The alternative keeps a repository variable for the name and a version file for the tag beside the dev container file, which makes three copies of one fact, and the day one of them lags is the day CI stops testing what developers run.

So a release workflow bumps `.devcontainer.json` and nothing else, and every job follows. A job that needs some other image says so with the `image` input, which also covers a project that has no dev container file at all.

## Why not a container job

`container:` pulls the image before the first step runs, so a job cannot build the image it needs. The image also lives only in this runner's Docker daemon, so it reaches another job only as an artifact, which is what `share` uploads. Each job still resolves its image with a step of its own, so this is an action rather than a reusable workflow.

## Building once per run

A workflow with several jobs in the dev image would build a candidate in every one of them. With these entry points one job builds it and the rest load it.

| Entry point | Job | What it does |
| --- | --- | --- |
| `h3nc4/dev-image-action/share` | one, first | Resolves the image as usual. When it built a candidate, saves it under the published name, compressed with zstd or else gzip, and uploads that as an artifact kept for one day. |
| `h3nc4/dev-image-action` | every other | Given `artifact`, downloads and loads that image before resolving, then finds the pin already present and runs in it as it is. |
| `h3nc4/dev-image-action/cleanup` | last | Deletes the artifact once every job is done with it. |

```yaml
jobs:
  dev-image:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.dev.outputs.image }}
      artifact: ${{ steps.dev.outputs.artifact }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - id: dev
        uses: h3nc4/dev-image-action/share@v3

  test:
    needs: [dev-image]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: h3nc4/dev-image-action@v3
        with:
          image: ${{ needs.dev-image.outputs.image }}
          artifact: ${{ needs.dev-image.outputs.artifact }}
          base-sha: ""
      - run: $DEV_RUN -c 'make test'

  dev-image-cleanup:
    needs: [dev-image, test]
    if: always() && needs.dev-image.outputs.artifact != ''
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      - uses: h3nc4/dev-image-action/cleanup@v3
        with:
          artifact: ${{ needs.dev-image.outputs.artifact }}
```

When `share` built nothing, its `artifact` output is empty and it doesn't upload. Every job then pulls the published image as it would without `share`. The other jobs pass an empty `base-sha` because the `share` job already compared the change. A shallow checkout and the default `image-inputs` are then enough for them, and a missing base commit cannot start a build of their own. Give `share` the inputs one job would take, such as `image`, `dockerfile` and `image-inputs`. The `share` job runs in the candidate too, through the same `DEV_RUN`, and can do work of its own.

`cleanup` needs `actions: write` and calls the REST API with `github.token`. A pull request from a fork gets a read-only token, so the delete is refused there with a warning, and the one-day retention removes the artifact instead. List every consuming job under its `needs`, or the delete can land before a job has loaded the image.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `devcontainer-file` | `.devcontainer.json` | Dev container definition the published image is read from, tag and all. |
| `image` | empty | Published image, with its tag, overriding the dev container file. |
| `dockerfile` | `docker/dev.Dockerfile` | Dockerfile to build when the image inputs moved. |
| `image-inputs` | `docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh` | Space-separated paths that decide a rebuild. List the Dockerfile and everything it copies. |
| `workdir` | `/workspace` | Where the checkout is mounted inside the container. |
| `base-sha` | the event's base | Commit to compare against. Override it to force a decision. |
| `cache-from` | empty | Passed to `buildx --cache-from`, such as `type=gha`. |
| `cache-to` | empty | Passed to `buildx --cache-to`, such as `type=gha,mode=max`. |
| `docker-args` | empty | Extra flags for the exported invocation, appended so they win. |
| `artifact` | empty | Artifact from a `share` job to load before resolving. The image inputs are then not compared. |
| `artifact-path` | empty | Directory a step of the caller's own downloaded that artifact into, for a forge where `actions/download-artifact` refuses to run. |

`share` takes the same inputs apart from those two, plus these:

| Input | Default | Meaning |
| --- | --- | --- |
| `artifact` | `dev-image` | Artifact the candidate is uploaded as. Give each `share` in a workflow its own. |
| `upload` | `true` | `false` saves the candidate and stops there. The caller then moves the archive itself. |

`cleanup` takes `artifact`, the name to delete, and `token`, which defaults to `github.token`.

## Outputs and exports

`image` is the output. `DEV_IMAGE` and `DEV_RUN` reach later steps through the environment.

`share` exports the same two, which point at the candidate itself when it built one. Its outputs are what the other jobs pass on:

| Output | Meaning |
| --- | --- |
| `image` | The published name, which a job that loads the artifact finds already present. |
| `artifact` | Name of the uploaded artifact, empty when nothing was built. |
| `path` | Archive the candidate was saved to, empty when nothing was built. |

## Requirements

**Pin the image with a tag.** The `image` key has to read `you/yourproject-dev:7`, not `you/yourproject-dev`. A reference with no tag pulls whichever image `latest` points at that morning, which is the opposite of a pin, so the action refuses one rather than resolving something it cannot name. The tag belongs to the last path element, since a colon before that one is a registry's port.

**Check out with `fetch-depth: 0`.** The decision is a diff against the base commit, and a shallow checkout leaves that commit out of the clone. The action treats a missing base as one that rules nothing out, and it builds a candidate on every run. A shallow clone still passes, at the price of that rebuild each time.

**Log in before the pull.** A job that skips the rebuild pulls the published image instead, and pulling anonymously counts against a rate limit shared with every runner on the same address. Private repositories refuse it outright. Put `docker/login-action` before this step. The pull happens inside it, and a pull that fails does not stop the job: the image gets built from the checkout instead, under a warning that says so. That is what makes a first publish work, and it means a missing login costs a rebuild rather than a red run.

**Pass what the action cannot assume.** Where the build tool keeps its cache, and any device the suite needs, belong in `docker-args`:

```yaml
- uses: h3nc4/dev-image-action@v2
  with:
    docker-args: -e GRADLE_USER_HOME=/workspace/.gradle-ci --device /dev/kvm
```

Later flags override earlier ones, so `docker-args` can replace a default such as `-w`, and mounts simply add.

## How it decides

The action diffs `base-sha` against `HEAD`, limited to `image-inputs`.

* Nothing listed changed, so the job runs in the image the dev container file pins. An image of that name already in the daemon is used as it is, since a tag that `docker load` brought in exists in no registry. Otherwise it is pulled.
* An `artifact` was given, and `share` already decided. The comparison is skipped, and the loaded image counts as present.
* A listed path moved, so the job runs in a locally built `<image name>:candidate`. That name has no namespace, which keeps anything from trying to pull it.
* The base is absent or all zeroes, which is what a branch's first push reports. There is nothing to compare, so the published image stands.
* The base no longer resolves, which is what a force-push leaves behind. Nothing can be ruled out, so it builds.
* The published image cannot be pulled, so it builds and warns. A project that has never published its first image starts here, without a bootstrap step of its own.

## Caching between runs

`share` removes the rebuild in every job of one run. `cache-from` and `cache-to` with `type=gha` also shorten the one build that remains, by reusing layers from earlier runs. Caching stays off unless asked for, because an image squashed into one layer gains little from a cache entry and can crowd everything else out of a small budget.

## Forgejo

Resolving runs on Forgejo unchanged. The artifact hand-off needs the following there, measured on Forgejo 17.0.1.

**Upload and download with Forgejo's fork.** `actions/upload-artifact` and `actions/download-artifact` from v4 on refuse every server other than github.com with `GHESNotSupportedError`. Forgejo serves the same artifact protocol, and `https://data.forgejo.org/forgejo/upload-artifact@v4` and its download twin talk to it. So pass `upload: "false"` to `share` and upload its `path` output yourself, then download in each consumer and point `artifact-path` at the directory:

```yaml
- id: dev
  uses: h3nc4/dev-image-action/share@v3
  with:
    upload: "false"
- if: steps.dev.outputs.artifact != ''
  uses: https://data.forgejo.org/forgejo/upload-artifact@v4
  with:
    name: ${{ steps.dev.outputs.artifact }}
    path: ${{ steps.dev.outputs.path }}
    retention-days: 1
    compression-level: 0
```

```yaml
- if: needs.dev-image.outputs.artifact != ''
  uses: https://data.forgejo.org/forgejo/download-artifact@v4
  with:
    name: ${{ needs.dev-image.outputs.artifact }}
    path: ${{ runner.temp }}/dev-image
- uses: h3nc4/dev-image-action@v3
  with:
    image: ${{ needs.dev-image.outputs.image }}
    artifact: ${{ needs.dev-image.outputs.artifact }}
    artifact-path: ${{ runner.temp }}/dev-image
    base-sha: ""
```

**Keep the results URL open to the runner.** The fork uploads to `ACTIONS_RESULTS_URL`, which Forgejo sets to its own public address. A proxy in front of that address that challenges or blocks the runner fails the upload with its own HTML page.

**Have jq or node in the job image for `cleanup`.** Forgejo answers the same REST endpoints, under `/api/v1`, with a bare array where GitHub wraps the list in an object, and `cleanup` reads both through whichever of the two it finds. The job container needs `curl` as well. `cleanup` warns rather than failing when the API refuses, so a token without the right to delete leaves the artifact to its retention.

A runner whose jobs share one Docker daemon keeps the published tag a consumer loaded. A later job on that daemon with the same pin then uses it without a pull, which is the rule above working as written, and also the reason `share` puts back whatever tag it borrowed.

## Tests

`./tests/resolve.test.sh` builds a throwaway repository and walks every decision above. It also covers what the action refuses, which is a dev container file that is absent, one without an image key, and a reference without a tag. It hands a candidate from `share.sh` to `load.sh` through a real archive, and runs `cleanup.sh` against a stand-in for curl serving both forges' listings. It then proves the exported invocation runs a command in the image, with the checkout mounted and any extra flags forwarded. It needs docker and git, plus jq or node for the cleanup cases, and it runs anywhere rather than only on a runner. CI runs it alongside jobs that use the actions for real. Two of them sit on either side of the decision. In the others `share` uploads a candidate, a consumer loads it, and `cleanup` deletes it and checks that the artifact is gone.

## License

<!-- vale off -->

BSD 2-Clause License. See [LICENSE](LICENSE).

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

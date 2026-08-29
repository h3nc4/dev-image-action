# dev-image-action

Runs your CI in your own dev container image, and rebuilds that image from the branch whenever the change touches it.

A project with a dev container usually pins it, so CI pulls a published tag. That leaves a gap: a pull request editing the Dockerfile proves only that the image still builds, never that the suite passes inside it. This action makes the suite run in the edited image. It compares the change against its base, and when a path that shapes the image has moved, it builds the image from the checkout and points the job at that instead of the tag it is about to replace. Nothing is pushed.

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0
- uses: h3nc4/dev-image-action@v1
  with:
    published-repo: you/yourproject-dev
- run: $DEV_RUN -c 'gradle --no-daemon test'
```

That is the whole integration. The step exports `DEV_RUN`, a small script that runs one command inside the resolved image with the checkout mounted, so a job step stays one line whichever image it got. The command goes through bash when the image has it and through `/bin/sh` otherwise.

## Why not a container job

`container:` pulls the image before the first step runs, so a job cannot build the image it needs, and it cannot pass flags such as `--device /dev/kvm` for an emulator. The image also lives only in this runner's Docker daemon, so it cannot cross to another job. Every job resolves it for itself, so this is an action rather than a reusable workflow.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `published-repo` | required | Repository of the published image, without a tag. |
| `version-file` | `.github/VERSION` | File holding the tag to pull when no rebuild is needed. |
| `dockerfile` | `docker/dev.Dockerfile` | Dockerfile to build when the image inputs moved. |
| `image-inputs` | `docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh` | Space-separated paths that decide a rebuild. List the Dockerfile and everything it copies. |
| `workdir` | `/workspace` | Where the checkout is mounted inside the container. |
| `base-sha` | the event's base | Commit to compare against. Override it to force a decision. |
| `cache-from` | empty | Passed to `buildx --cache-from`, such as `type=gha`. |
| `cache-to` | empty | Passed to `buildx --cache-to`, such as `type=gha,mode=max`. |
| `docker-args` | empty | Extra flags for the exported invocation, appended so they win. |

## Outputs and exports

`image` is the output. `DEV_IMAGE` and `DEV_RUN` reach later steps through the environment.

## Requirements

**Check out with `fetch-depth: 0`.** The decision is a diff against the base commit, and a shallow checkout cannot reach it. The action then falls back to the published image, so a shallow clone doesn't fail. It just stops testing candidates.

**Log in before the pull.** A job that skips the rebuild pulls the published image instead, and pulling anonymously counts against a rate limit shared with every runner on the same address. Private repositories refuse it outright. Put `docker/login-action` before this step. The pull happens inside it, and a pull that fails does not stop the job: the image gets built from the checkout instead, under a warning that says so. That is what makes a first publish work, and it means a missing login costs you a rebuild rather than a red run.

**Pass what the action cannot assume.** Where your build tool keeps its cache, and any device the suite needs, belong in `docker-args`:

```yaml
- uses: h3nc4/dev-image-action@v1
  with:
    published-repo: you/yourproject-dev
    docker-args: -e GRADLE_USER_HOME=/workspace/.gradle-ci --device /dev/kvm
```

Later flags override earlier ones, so `docker-args` can replace a default such as `-w`, and mounts simply add.

## How it decides

The action diffs `base-sha` against `HEAD`, limited to `image-inputs`.

* Nothing listed changed, so the job runs in `published-repo:<version-file>`.
* A listed path moved, so the job runs in a locally built `<image name>:candidate`. That name has no namespace, which keeps anything from trying to pull it.
* The base is absent or all zeroes, which is what a branch's first push reports. There is nothing to compare, so the published image stands.
* The base no longer resolves, which is what a force-push leaves behind. Nothing can be ruled out, so it builds.
* The published image cannot be pulled, so it builds and warns. A project that has never published its first image starts here, without a bootstrap step of its own.

## Caching between jobs

Building the candidate once per job is the price of every job resolving its own image. `cache-from` and `cache-to` with `type=gha` shift most of that cost to the Actions cache. Caching stays off unless you ask for it, because an image squashed into one layer gains little from a cache entry and can crowd everything else out of a small budget.

## Tests

`./tests/resolve.test.sh` builds a throwaway repository and walks every decision above. It then proves the exported invocation runs a command in the image, with the checkout mounted and any extra flags forwarded. It needs docker and git, and it runs anywhere rather than only on a runner. CI runs it alongside two jobs that use the action for real, one on each side of the decision.

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

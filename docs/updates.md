<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Package updates: pinning, update PRs, local AI review

Fedora moves under us every week (kernel, Mesa, Plasma, firmware). This
pipeline makes that visible and reviewable instead of a surprise at the next
build:

1. **Pin.** `lock/` records, per image, the exact package versions (NEVRA,
   repo, checksum) and the base images by digest. A pinned build installs
   exactly those.
2. **Detect.** A weekly workflow re-resolves against Fedora 45 and opens a PR
   with the new `lock/` and a Markdown diff (watched packages first, with
   what to test).
3. **Check.** CI runs on the PR branch: lint/tests, device trees and kernel
   modules against the newest Fedora kernel (the compile-time kernel guard),
   and a pinned image build (dependency conflicts).
4. **Review.** On the Mac, `tools/update/review-pr.sh <pr>` gathers
   changelogs, Bodhi feedback, Bugzilla and upstream issues for the changed
   packages, asks a **local** model (Ollama) for a risk level per package, and
   posts that as a PR comment.

Nothing here talks to a phone. Testing on the phone stays a human step: the
PR lists what to test for every watched package.

## Files
| Path | What |
|---|---|
| `tools/update/targets.yaml` | the images we lock: base image, sources (or device + desktop for bootc images) |
| `tools/update/lock.py` | resolve the targets, write `lock/` |
| `tools/update/dnf-helper.py` | libdnf5 resolver/changelog reader; runs *inside* a Fedora container |
| `tools/update/check-updates.py` | re-lock + diff old vs new → JSON + Markdown |
| `tools/update/watched-packages.yaml` | packages our workarounds depend on, what to test, cookbook recipe, upstream keywords |
| `tools/update/review.py` | evidence + local LLM → Markdown risk review |
| `tools/update/review-pr.sh` | run the review for a PR and comment on it (`gh`) |
| `tools/update/launchd/` | launchd template to run the review weekly on the Mac |
| `tools/update/pin-context.sh`, `tools/image/pin-packages` | install the versionlock for a pinned build |
| `lock/<target>.rpms.lock.yaml` | the record: base image (digest, `rpm -qa`), our steps, resolved packages |
| `lock/<target>.versionlock.toml` | the same, in dnf5's versionlock format (what a pinned build uses) |
| `lock/<target>.images.env` | `BASE_IMAGE=`/`KERNEL_IMAGE=` by digest |
| `.github/workflows/update.yml` | weekly re-lock + PR |

## Pinning

### How a lock is made
`tools/update/lock.py [--target <name>]` (podman; on the Mac's podman machine
or an `ubuntu-24.04-arm` runner, both aarch64):

1. Extract the `dnf5 install/remove` commands from the target's
   Containerfiles/build scripts, in order (`--list-steps` shows them). bootc
   targets use the same layer order as the Containerfile, with the boot
   method from the device's `device.env`.
2. Pull the base image, record its digest (and, for netroot/installroot, the
   digest and `kernel*` packages of `KERNEL_IMAGE`, where `/usr/lib/modules`
   comes from).
3. In a container of the base image: copy its rpmdb aside, install
   `python3-libdnf5` if needed, and resolve all steps as one libdnf5
   transaction against the copied rpmdb. Nothing is installed; the result is
   "what our build steps would install on top of this exact base image".
4. Write the three files per target.

Known simplifications: one transaction per target, so `install_weak_deps`
is the most permissive of the target's steps (since decision 0003 every
step is without weak deps: layers' `packages` lists always are).
Layer sources: a layer's `packages` and `packages.<target>` files, plus,
for bootc targets, its `build` script; dev-root targets (`kind: devroot`)
read the netroot Containerfile and the lists only. Removals use `allow_erasing`, as `dnf5 remove`
does. Specs with shell variables (`"$KERNEL_PACKAGE"`) can't be resolved and
are reported.

A target that no longer resolves keeps its old lock and is reported at the
top of the update PR (exit code 1/3). First catch, 2026-11-20:
**`oneplus-billie2-phosh` did not resolve: `squeekboard` is no longer in
Fedora 45** (`stevia`, Phosh's own keyboard, is). Fixed with the explicit
phosh list; locked since.

### Pinned builds (opt-in; default stays "newest")
| Build | Pinned | Default |
|---|---|---|
| bootc image | `just PINNED=1 DEVICE=… DESKTOP=… build` (or `FAP_PINNED=1` in `.env`) | `just build` |
| netroot | `FAP_PINNED=1 boot/android-bootimg/make-netroot.sh <out>` | as before |
| dev root | `FAP_PINNED=1 boot/android-bootimg/make-devroot.sh <device> <desktop> <out>` (lock `DEVROOT_LOCK`, default `<device>-<desktop>-devroot`; netroot pinned too) | as before |
| installroot | `FAP_PINNED=1 …/installroot/make-installroot.sh <out>` (lock `installroot`) | as before |
| CI | `build.yml` input `pinned` | off |

Mechanism: dnf5's own **versionlock** (`/etc/dnf/versionlock.toml`, one
`evr =` condition per locked package) plus Fedora's **updates-archive** repo
(`tools/image/fap-updates-archive.repo`). The archive matters: Fedora's
`updates` repo keeps only the newest build of each package, so a locked
version becomes unavailable the day it's superseded; the archive keeps every
update that reached stable. The base images are pinned by digest
(`BASE_IMAGE`, `FEDORA_IMAGE`, `KERNEL_IMAGE` build args). The versionlock
is removed at the end of the build, so images don't ship it. Base-image
packages aren't in the versionlock: the digest pins them, and the locked
packages need exactly what they needed at lock time.

Verified 2026-11-20: pinned netroot build on the Mac (fedora:45 and
silverblue:45 by digest); all 116 locked packages installed at the locked
version, including one deliberately set to a superseded version
(`less-710-1.fc45`, only in updates-archive). Not yet verified: a pinned bootc
image build (`just build` itself hasn't run yet, docs/status.md).

To flip the default later: set `FAP_PINNED=1` in `.env` (Justfile) and in
the scripts' callers, and make `build.yml`'s `pinned` default `true`.

### Evaluation: konflux `rpm-lockfile-prototype`
Considered first (it's what Konflux/Hermeto use). Not adopted, because:
- it takes a flat package list in its own `rpms.in.yaml`, so our package
  lists would live twice; we have ordered steps with removals and differing
  weak-dependency settings spread over Containerfiles and build scripts;
- it needs dnf4's Python bindings (`python3-dnf`) and skopeo; Fedora 45 is
  dnf5-only in our containers, and libdnf5's bindings do the job directly;
- its output (URLs + checksums) is for hermetic prefetch into a local repo.
  We don't build hermetically; dnf5's versionlock + the updates archive pins
  without a prefetch step.
`lock/*.rpms.lock.yaml` still records repo, checksum, size and repo-relative
location per package, so a Hermeto-style prefetch could be added later.

## Detecting updates
`just update-check` (= `tools/update/check-updates.py`) re-locks into a temp
dir and prints the diff; `--write` updates `lock/` in place; `--changelogs`
adds RPM changelogs (entries newer than our old version, from the repo
metadata via `dnf-helper.py`); `--json`/`--markdown` write files;
`--old A --new B` only diffs two lock dirs (no podman).

The diff is per **source package** (what Fedora builds and Bodhi ships):
old → new NVR, binary packages, targets, and whether it's watched. Base
image digest changes are listed too; packages that come with the base
image (kernel, Mesa, Plasma on Kinoite) are diffed from the recorded
`rpm -qa`, so they show up like any other package.

`.github/workflows/update.yml` runs this weekly (Mondays 03:41 UTC) on an
arm64 runner and, when `lock/` changed, opens or updates the PR
`update/fedora-packages` with the Markdown as its body. PRs created with
`GITHUB_TOKEN` don't trigger push workflows, so the workflow dispatches
`ci.yml` and `build.yml` (`pinned=true`, `tty`) on the PR branch itself.
Optional: an `UPDATE_BOT_TOKEN` secret (fine-grained PAT, contents +
pull-requests write) makes the PR come from that token, so the usual
push-triggered checks run too.

### Watched packages
`tools/update/watched-packages.yaml` lists what our workarounds and drivers
depend on: Mesa/freedreno (`noubwc`), the kernel (kmods, DTs, interconnect
and USB DT fixes), SDDM/Plasma Mobile/KWin, PipeWire/WirePlumber (null
sink), NetworkManager/dnsmasq (`usb0`), Waydroid/LXC/gbinder, the modem
userspace (rmtfs/qrtr/tqftpserv/pd-mapper), firmware packages, systemd.
Each entry has `why`, the cookbook `recipe`, a `test` checklist (copied into
the PR) and `keywords`/`upstream` for issue searches. Add an entry whenever
a new workaround depends on a package.

## Local AI review

### What it does
`tools/update/review.py <updates.json>`, usually via
`tools/update/review-pr.sh <pr>` (`just update-review <pr>`):

1. Evidence per changed source package, each numbered `E1…`:
   changelog since our version; the **Bodhi** update for the new build
   (status, karma, gating, non-bot comments, negative ones first, fixed
   bugs, security flags); for watched or Bodhi-flagged packages also
   **Red Hat Bugzilla** (Fedora 45 bugs for the component changed in the
   last 90 days) and upstream trackers filtered by the package's keywords
   (gitlab.freedesktop.org issue titles, bugs.kde.org, GitHub).
2. One request per package to the local model (OpenAI chat-completions
   API, `temperature 0`, JSON mode) with a strict prompt: use only the
   evidence, cite evidence IDs for every reason, answer
   `{"risk": low|medium|high, "reasons": [...], "test_focus": [...]}`.
3. Validation: reasons citing no existing evidence ID are dropped (and
   counted in the comment); unusable output is retried once, then shown as
   "unknown".
4. Markdown: a risk table, per package the reasons linked to their
   evidence, the evidence list (collapsed), and the quiet updates as one line
   each. `review-pr.sh` posts it as a PR comment and updates that same
   comment on later runs.

Scope, to keep a weekly run short: Bodhi for every upgraded package;
Bugzilla, upstream and the LLM for watched packages and anything Bodhi
flags (negative karma, security bugs, not yet stable). `--all` reviews
everything; `--no-llm` gives evidence only.

**Offline-ish by design:** if the model isn't reachable, the comment still
has all the evidence, marked "AI summary unavailable". HTTP responses are
cached (`~/.cache/fap-update`, 12 h; `FAP_CACHE`), requests are paced to one
per second per host with backoff on 429/5xx and send a descriptive
User-Agent; `--offline` uses only the cache.

### Running the model on the Mac
Ollama is installed (`/opt/homebrew/bin/ollama`).
```sh
ollama serve                 # or start the Ollama app / brew services start ollama
ollama pull qwen2.5:14b      # default model, ~9 GB
tools/update/review-pr.sh <pr> --dry-run     # print instead of commenting
tools/update/review-pr.sh <pr>
```
Settings (environment): `FAP_LLM_URL` (default
`http://localhost:11434/v1`), `FAP_LLM_MODEL` (default `qwen2.5:14b`),
`FAP_LLM_TIMEOUT` (seconds, default 300). No API key is sent; any
OpenAI-compatible server (llama.cpp's `llama-server`, LM Studio) works.

Model choice (suggestions, not benchmarked here): `qwen2.5:14b` on a Mac
with 16 GB or more; `qwen2.5:7b` or `llama3.1:8b` (~5 GB) on smaller
machines or for speed; `qwen2.5:32b` with 32 GB+ if you want more careful
reasoning. The task is reading short evidence lists and following a JSON
schema, which mid-size instruction models do well; the evidence-ID
validation catches made-up reasons whatever the model. Ollama's default
context is small; prompts are capped at ~7000 characters of evidence.

**Privacy:** everything stays local or public. Public APIs get package
names and versions (Bodhi, Bugzilla, GitLab, KDE, GitHub; no credentials).
The model runs on the Mac and only sees that public evidence; `gh` uses
your login only to read the PR and post the comment.

### Scheduled reviews (optional)
`tools/update/launchd/org.fap.update-review.plist.template` runs
`review-pr.sh --latest` (newest open PR from `update/fedora-packages`) on
Tuesdays 09:00; install instructions are in the file. Logs:
`~/Library/Logs/fap-update-review.log`.

## Turning it on
1. Merge this branch; push. The `update` workflow appears under Actions
   (manual run: "Run workflow"). It needs Actions to be allowed to create
   PRs (Settings → Actions → General → "Allow GitHub Actions to create and
   approve pull requests").
2. Optional: `UPDATE_BOT_TOKEN` secret (see above).
3. On the Mac: `ollama serve`, `ollama pull qwen2.5:14b`, then
   `just update-review <pr>` for each update PR (or install the launchd job).
4. When ready, flip pinned builds to the default (above).

## Tests
`tools/tests/test_update.py` (in `python3 -m unittest discover -s
tools/tests`, CI's lint job): version comparison, step extraction, lock
diffing (installonly kernels, base digests, kernel image), report and
truncation, changelog slicing, Bodhi/Bugzilla/GitLab/GitHub parsing against
recorded fixtures (`tools/tests/fixtures/update/`), the evidence-ID
validation, review.py end to end against a fake OpenAI-compatible server,
the unreachable-model path, and the HTTP cache.

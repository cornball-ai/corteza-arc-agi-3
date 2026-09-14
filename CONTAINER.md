# ARC protocol v5 container

`build-container.sh` fetches the public dependency revisions in `sources.lock`
and verifies the archived dependency's SHA-256. It archives this harness's
committed `HEAD`, restricted to `runtime-files.txt`, and installs the sources
over a digest-pinned R image. `SOURCE-MANIFEST.txt` records source URLs,
commits, versions, and content hashes. No sibling package checkouts or local
package cache are required, and nothing is installed into the host R library.
The Matrix reporter is host-only and isn't copied into the image.

Uncommitted source edits cannot enter the staged payload. The base image and
listed sources are pinned; apt repository packages aren't, so this isn't a
claim of bit-for-bit reproducible images. Commit intended changes before
building, and change `sources.lock` explicitly when upgrading dependencies.

`run-container.sh` starts one clean 25-game campaign with these fixed defaults:

- local run label: `cold-claude-opus-5` (scorecard tags remain version-free)
- tags: `corteza`, `rlm`, `cold`, `claude-opus-5`
- model/provider: `claude-opus-5` / `anthropic`
- five independent workers on one shared scorecard
- deterministic shortest-to-longest human-baseline queue with greedy refill
- reasoning effort `max`, thinking budget `0`
- output cap `48,000` including the configured reasoning headroom
- action budget: five times each game's human baseline
- protocol v5 and no inherited done hashes or wins
- supervised persistent R analysis worker, at most 600 seconds per call
- no subagent tools

The analysis worker uses corteza's standard `run_r_mode = "worker"` dispatch.
The ARC adapter supplies `session$run_r_timeout_cap` through the standard
dispatcher, a shrinking per-call cap from time since the last
game action: `min(600, 900 - 120 - elapsed)`, floored at zero. The 120-second
reserve leaves time for another model response and action before the documented
[15-minute scorecard inactivity close](https://docs.arcprize.org/toolkit/close-scorecard).
This is conservative per game; activity in another worker does not reset its
local allowance. It reduces avoidable idle compute but cannot guarantee that
model/API latency or an outage stays within ARC's lease.

On timeout, corteza interrupts the R worker, retaining completed assignments
when it stops cleanly. If it cannot stop within the grace period, the worker is
terminated; the next R call restores its last successful workspace checkpoint.
Each completed analysis call checkpoints the worker's objects and helpers.
The parent continues to own credentials, game mutations, and immutable action
limits. The model's only tools remain `run_r` and `game_action`.

Protocol v4 records remain readable by the monitors. They cannot resume or count
as completions in a v5 campaign. Scorecard tags do not gain a version or date.
The manifest freezes the worker count, so resuming with a different count is
refused; choose that count before opening a card.

The image filesystem and harness are read-only. Campaign state is written into
the canonical `campaigns/` directory, so the Matrix watcher and board monitor
can see all workers. Each game writes a private cookie jar seeded from the
freshest worker session that has successfully bootstrapped a game. Only a
one-key ARC Renviron file, the Anthropic key, and
the unused-by-this-provider Codex OAuth cache mount enter the container. The
launcher refuses an existing label unless `ARC_CONTAINER_RESUME=1` is set.

Build now:

```sh
./build-container.sh
```

Launch only after explicitly choosing a fresh campaign label:

```sh
./run-container.sh
```

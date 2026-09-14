# corteza ARC-AGI-3 harness

ARC-AGI-3 evaluation harness for running corteza as an RLM agent.
It keeps the game client and immutable action controller outside the model-owned persistent R analysis environment, runs one game per process, and records a complete campaign under one ARC scorecard.

## Provenance

The behavioral prompt and protocol design directly use [Prime Intellect's ARC-AGI-3 Prime Agent](https://github.com/PrimeIntellect-ai/arc-agi-3-prime-agent) as a design source. Prime's published guidance established the comparison floor for isolation, chronological temporal frames, programmatic analysis, hypothesis-driven actions, and autonomous continuation. The corteza harness implements those ideas in an R-native architecture with a persistent `run_r` environment, a one-action controller, a five-times-human action budget, durable reconciliation, and context compaction.

Prime Agent is MIT-licensed; its attribution and license are preserved in `THIRD_PARTY_NOTICES.md`. This repository is not affiliated with or endorsed by Prime Intellect or the ARC Prize Foundation.

## Build

On Linux, install Docker, Bash 5.1 or newer, git, curl, GNU coreutils, and
R with littler (`r`). The launcher uses littler to prepare a minimal
credential file. The optional dashboard also needs tmux and the host R
packages `jsonlite` and `digest`.

The build fetches public dependency commits and a checksum-verified archive
listed in `sources.lock`. It takes this harness from its committed `HEAD`,
using `runtime-files.txt` as the image's file allowlist. It doesn't depend on
sibling checkouts or change installed host packages:

```sh
./build-container.sh
```

## Run

Configure `ARC_PRIZE` (or `ARC_API_KEY`) and `ANTHROPIC_API_KEY` in your
environment or `~/.Renviron`. Don't commit credentials. The default provider
is `anthropic`; other supported providers can be selected with `ARC_PROVIDER`
and `ARC_MODEL`. Codex OAuth uses the cache selected by `ARC_TOKEN_CACHE`.

A fresh complete campaign runs five independent game workers on one scorecard. The deterministic queue is shortest-to-longest by summed human baseline; whenever a worker finishes, it greedily claims the next game.

```sh
ARC_CAMPAIGN_LABEL=cold-claude-opus-5 ./run-container.sh
```

A selected-game rehearsal accepts slugs after the launcher:

```sh
ARC_CAMPAIGN_LABEL=compaction-rehearsal ./run-container.sh wa30
```

Campaign artifacts are written beneath `campaigns/` and deliberately excluded from git. The opening manifest freezes the expected game set and worker count. Each worker seeds a private per-game cookie jar from the freshest worker session that has successfully bootstrapped a game, so concurrent ARC sessions cannot overwrite one another and queued games inherit current affinity. A missing game during bootstrap is retried locally; only an explicit missing card id stops all active workers. Final verification refuses to close a card until every expected game has a matching completed record. Use `campaign.R abandon` only to end an intentionally incomplete rehearsal.

Protocol v5 uses corteza's supervised persistent R worker. Analysis calls have
a host maximum of 600 seconds, shortened as ARC inactivity accumulates, with
120 seconds reserved for the next model response and game action. R objects
and helpers are checkpointed after analysis; interrupted work reports whether
state survived. See `CONTAINER.md` for timeout and recovery behavior.

## Monitor

From the checkout, start a 3-by-2 tmux dashboard with a summary and 5 games:

```sh
./watch-tmux.sh cold-claude-opus-5
tmux attach -t arc-agi-3
```

The optional Matrix reporter runs on the host and requires `cerebro` and its
configured Matrix client. Set `ARC_MATRIX_ROOM` to your destination room,
`ARC_MATRIX_CONFIG` to the client config file, and `ARC_MATRIX_INSTANCE_DIR`
to the bot's instance directory. These have no built-in personal defaults.
Then post once or omit `ARC_WATCH_ONCE` to post every 30 minutes:

```sh
ARC_CAMPAIGN_LABEL=cold-claude-opus-5 ARC_WATCH_ONCE=1 Rscript --vanilla watch-room.R
```

## Offline tests

Inside the built image, the tests need no API key or network access:

```sh
docker run --rm --network none --entrypoint Rscript corteza-arcagi3:v5 \
  --vanilla -e 'x <- tinytest::run_test_file("test-protocol.R"); stopifnot(all(as.logical(x)))'
```

## License

MIT for original work in this repository. Third-party notices remain separately applicable.

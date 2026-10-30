# aider-bench

One script to run [Aider's polyglot benchmark](https://github.com/Aider-AI/aider/blob/main/benchmark/README.md)
(225 exercises: C++, Go, Java, JavaScript, Python, Rust) against any OpenAI-compatible endpoint,
such as a local vLLM, SGLang or llama.cpp server. Everything runs inside the official `aider-benchmark` Docker image.

On top of the stock harness it adds:

- **Settings from flags.** The aider model settings file is generated from command-line flags.
- **Live results.** One coloured PASS/FAIL line per finished exercise, with a running score.
- **A request log.** The real request parameters sent to the server, plus success or error, finish reason and tokens.
- **Per-language stats.** A per-language table after the usual stats.
- **Partial reruns.** `--redo` reruns only the exercises that hit context limits, failed, crashed or had errors.
- **Extra instructions.** `--system-prefix` and `--user-prefix` add your own text to the prompts.
- **The grep-ast `.h` fix.** grep-ast 0.9.0, the version aider pins, parses `.h` files with the C grammar, which
  rejects C++ (namespaces, templates, classes). C++ headers then produce false lint errors that cost extra turns. At
  every start the script changes that one mapping line in the container's grep-ast to `cpp`, and stops if the result
  isn't `cpp`. This is the same change as grep-ast PR #24, whose fork and PR are no longer on GitHub.

## Requirements

Linux with `bash`, `git`, `docker` and `python3`. On the first run the script:

- clones aider into `~/aider`
- clones the exercises into `~/aider/tmp.benchmarks/polyglot-benchmark`
- builds the `aider-benchmark` image from aider's own
  [`benchmark/Dockerfile`](https://github.com/Aider-AI/aider/blob/main/benchmark/Dockerfile) via `benchmark/docker_build.sh`

The image provides the language toolchains. aider itself is installed from the mounted `~/aider` checkout at every
start, so a `git pull` there takes effect right away. The image is not rebuilt automatically: after a Dockerfile change
upstream, run `docker rmi aider-benchmark` and the next run rebuilds it.

## Quick start

```bash
./aider-bench.sh --run --url http://127.0.0.1:8000/v1 --model mymodel --format whole \
  --max-tokens 65536 --threads 4 --stats runs/mymodel-whole
```

- `--model` is the model name your server serves. aider calls it as `openai/<model>`.
- `--stats DIR` is both the output folder and the run name.

Smoke test with 5 exercises:

```bash
./aider-bench.sh --run --model mymodel --stats runs/smoke -- --num-tests 5
```

Show the stats of a finished or running run:

```bash
./aider-bench.sh --show --stats runs/mymodel-whole
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `--url URL` | `http://127.0.0.1:8000/v1` | OpenAI-compatible base URL |
| `--model NAME` | `myai` | Served model name |
| `--key KEY` | `dummy` | API key |
| `--format whole\|diff` | `whole` | aider edit format |
| `--max-tokens N` | `96384` | `max_tokens` per request. `0` sends none, so the server uses the remaining context. |
| `--threads N` | `4` | Exercises run in parallel |
| `--request-timeout SEC` | `3600` | How long aider waits for one reply before retrying (aider's own default is 600) |
| `--stats DIR` | `MODEL-FORMAT-MAXTOK` | Output folder; its name is the run name |
| `--runs N` | `1` | Run the whole benchmark N times and report the scores as mean ± error (see below) |
| `--redo WHAT,...` | | Rerun only matching exercises of the latest run with this name: `exhausted`, `failed`, `crashed`, `errors` or `LANG/EX` names, combined with commas (see below) |
| `--system-prefix TEXT\|@FILE` | | Text at the start of the system prompt (see below) |
| `--user-prefix TEXT\|@FILE` | | Text at the start of the last user message of every request (see below) |
| `--<aider_setting> V` | | Any aider model setting; see below |
| `-- ...` | | Passed to `benchmark.py`, for example `--num-tests 5`, `--new`, `--cont`, `--languages python,go` |

### aider model settings from flags

Flags with snake_case names go into the generated model settings file:

- **aider's own settings go at the top level:** `use_temperature`, `reasoning_tag`, `system_prompt_prefix`,
  `examples_as_sys_msg` and so on.
- **Everything else goes under `extra_params`,** which aider adds to every request: `top_p`, `top_k`, `min_p`,
  `temperature`, `repetition_penalty`, `presence_penalty`, ...

```bash
# send no temperature at all, so the server's sampling defaults apply (e.g. vLLM --override-generation-config)
./aider-bench.sh --run ... --use_temperature false

# vendor-recommended sampling, sent with every request
./aider-bench.sh --run ... --temperature 0.7 --top_p 0.8 --top_k 20 --min_p 0

# no thinking, and strip <think> blocks
./aider-bench.sh --run ... --system_prompt_prefix '"/no_think"' --reasoning_tag think
```

By default aider sends `temperature: 0`, as on the aider leaderboard.

### Extra instructions for the model

```bash
# at the start of aider's system prompt, on every request (aider's system_prompt_prefix)
./aider-bench.sh --run ... --system-prefix "Think step by step before writing code."

# at the start of the last user message of every request: the task, or the test errors on try 2
./aider-bench.sh --run ... --user-prefix @think-harder.txt
```

Both take the text itself or `@file` for longer prompts. The system prefix is stored in `model-settings.yml` and
the user prefix in `user-prefix.txt` in the output folder, so the run can be reproduced. Earlier messages in the
conversation are not changed.

## Output

While running, the terminal shows the progress bar, one line per finished exercise and compact request errors:

```
sent {"max_tokens": 65536, "model": "mymodel"}
PASS 2  python/beer-song                     106s  in  15.2k  out   3.8k   1/1 100.0%
  !  java/forth                         context overflow: prompt 30,049 + max_tokens 100,000 > 130,048
FAIL    java/forth                           466s  in  44.0k  out  10.5k   1/2  50.0%  errors=1 ctx=1 asks=1
```

Every failed request says what aider does next: `aider retries (retry N, after Xs)`, `try ends, counted as ctx`
(context overflow), `aider gives up on this request` or `unexpected error`. When a retried request finally succeeds,
a green `ok ... request succeeded after N failed attempt(s)` line follows. The same note is stored as `action` in
`requests.jsonl`.

`DIR` contains:

| File | Content |
|---|---|
| `run-<date>.log` | full benchmark output (model replies, test output) |
| `model-settings.yml` | the generated aider model settings |
| `requests.jsonl` | one line per model request: parameters actually sent (prompt and reply text left out), ok or error, finish reason, tokens, seconds |
| `results.jsonl` | one line per finished exercise |
| `stats.yml` | aider stats, per-language table and request summary |
| `results` | symlink to the raw run folder in `~/aider/tmp.benchmarks` |

## Repeated runs and error bars

Thinking models, sampling and batching on the server make results vary from run to run, even at temperature 0.
`--runs N` runs the whole benchmark N times with identical settings and reports each score as a mean with error bars:

```bash
./aider-bench.sh --run ... --stats runs/mymodel-whole --runs 5
```

Each run is an ordinary run in `DIR/NAME-r1` ... `DIR/NAME-rN`, with its own log, `requests.jsonl`, `results.jsonl`
and `stats.yml`. When all runs are done, and on `--show --stats DIR`, the series report shows, for example:

```
pass_rate_1:  50.6 ± 0.5 SE   95% CI ±1.4   SD 1.10   range 49.3-52.0   (5 runs)
pass_rate_2:  90.8 ± 0.4 SE   95% CI ±1.1   SD 0.85   range 89.8-92.0   (5 runs)
```

plus each run's scores, `pass_rate_2` per language, and the flaky exercises (passed in some runs but not all).
SE is the standard error of the mean (SD / √N); the 95% CI uses the t-distribution, so it is wide for 2-3 runs.

- The ± is run-to-run noise only. Every full run uses the same 225 exercises (only their order is shuffled).
- Rerunning the same command continues the series: unfinished runs continue, missing runs start. `-- --new` and
  `-- --cont` are ignored with `--runs`; use a new `--stats` name for a new series.
- Do not combine with `-- --num-tests`: each run would pick a different random subset of exercises.
- `--redo` with `--runs N` reruns the matching exercises in every started run, then prints the series report. For
  one run only, use `--stats DIR/NAME-rK --redo ...`, then `--show --stats DIR`. Redoing only some exercises gives
  them an extra chance, so mention it.
- Without `--runs` (or with `--runs 1`) everything works exactly as a normal single run.

## Rerunning part of a run

`--redo` renames the result files of matching exercises (they are not deleted) and continues the latest run with
the same `--stats` name, so only those exercises run again:

- `exhausted`: ran out of context window, or a reply hit `max_tokens`
- `failed`: did not pass
- `crashed`: the harness crashed on the exercise
- `errors`: failed, and had error outputs (failed requests, for example) or malformed replies
- `rust/bob`: exactly this exercise, as a `language/exercise` name

Combine them with commas; an exercise reruns if it matches any of them. Add `--redo` to the command you ran the
benchmark with:

```bash
./aider-bench.sh --run ... --stats runs/mymodel-whole --max-tokens 65536 --redo exhausted,errors

# a --runs series: the matching exercises of every run, then the series report
./aider-bench.sh --run ... --stats runs/mymodel-whole --runs 5 --redo exhausted,errors
```

Rerunning only some exercises gives them a second chance the others did not get. Report the original score
alongside the redone one.

To continue an interrupted run, repeat the same command with `-- --cont`. To start a new run under an existing
name, add `-- --new`.

## Things worth knowing

- **Keep prompt + `max_tokens` under the context length.** The second try resends the whole conversation, including
  the model's first answer and the test errors, so prompts grow. If prompt plus `max_tokens` is larger than the
  server's context length, the server rejects the request and aider counts a context overflow. Leave room: for
  example 65536 on a 128k-262k context model.
- **`--max-tokens 0`** avoids that error, but a looping model can then generate until the context is full.
- **Requests are not streamed** (`benchmark.py` sends `stream=False`), so a reply arrives only when it is complete.
  aider gives up after `--request-timeout` and retries from scratch; at temperature 0 a reply that is too slow
  tends to time out again on every retry. Proxies in front of the server need a read timeout at least that long.
- **Proxy 502s.** Some proxies turn the server's "maximum context length" 400 into a 502. aider retries 502s for up
  to 24 hours, so the exercise hangs. The script turns those back into context errors so the run moves on.
- **Ownership.** Results are written by root inside the container. The script hands the run folder back to your
  user when it builds the stats.

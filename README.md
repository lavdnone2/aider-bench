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
- **The grep-ast `.h` fix.** [grep-ast PR #24](https://github.com/Aider-AI/grep-ast/pull/24) is installed, so `.h` files
  are parsed as C++. Without it, C++ headers produce false lint errors that cost extra turns.

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
| `--stats DIR` | `MODEL-FORMAT-MAXTOK` | Output folder; its name is the run name |
| `--redo exhausted\|failed\|crashed\|errors` | | Rerun only matching exercises of the latest run with this name (see below) |
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

## Output

While running, the terminal shows the progress bar, one line per finished exercise and compact request errors:

```
sent {"max_tokens": 65536, "model": "mymodel"}
PASS 2  python/beer-song                     106s  in  15.2k  out   3.8k   1/1 100.0%
  !  java/forth                         context overflow: prompt 30,049 + max_tokens 100,000 > 130,048
FAIL    java/forth                           466s  in  44.0k  out  10.5k   1/2  50.0%  errors=1 ctx=1 asks=1
```

`DIR` contains:

| File | Content |
|---|---|
| `run-<date>.log` | full benchmark output (model replies, test output) |
| `model-settings.yml` | the generated aider model settings |
| `requests.jsonl` | one line per model request: parameters actually sent (prompt and reply text left out), ok or error, finish reason, tokens, seconds |
| `results.jsonl` | one line per finished exercise |
| `stats.yml` | aider stats, per-language table and request summary |
| `results` | symlink to the raw run folder in `~/aider/tmp.benchmarks` |

## Rerunning part of a run

`--redo` renames the result files of matching exercises (they are not deleted) and continues the latest run with
the same `--stats` name, so only those exercises run again:

- `exhausted`: ran out of context window, or a reply hit `max_tokens`
- `failed`: did not pass
- `crashed`: the harness crashed on the exercise
- `errors`: failed and had error outputs or malformed replies

```bash
./aider-bench.sh --run ... --stats runs/mymodel-whole --max-tokens 65536 --redo exhausted
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
- **Requests are not streamed** (`benchmark.py` sends `stream=False`), and aider stops waiting for a reply after
  600 seconds. Proxies in front of the server need a long enough read timeout, or long replies time out and get
  retried.
- **Proxy 502s.** Some proxies turn the server's "maximum context length" 400 into a 502. aider retries 502s for up
  to 24 hours, so the exercise hangs. The script turns those back into context errors so the run moves on.
- **Ownership.** Results are written by root inside the container. The script hands the run folder back to your
  user when it builds the stats.

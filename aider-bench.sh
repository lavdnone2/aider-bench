#!/usr/bin/env bash
# usage: ./aider-bench.sh --run [--url URL] [--model NAME] [--key KEY] [--format whole|diff] [--max-tokens N (0 = let server use remaining context)] [--threads N] [--request-timeout SEC] [--stats DIR] [--runs N] [--redo exhausted|failed|crashed|errors|LANG/EXERCISE,...] [--system-prefix TEXT|@FILE] [--user-prefix TEXT|@FILE] [--<aider_setting> V ...] [-- extra benchmark.py args]
#        ./aider-bench.sh --show [--stats DIR]
# --runs N: run the whole benchmark N times with the same settings (DIR/NAME-r1 .. rN), then report each score as
#   mean ± standard error over the runs. Rerunning the same command continues unfinished runs. Without it: one run.
# --redo: (errors = failed exercises that had error outputs or malformed replies) set aside matching results of the latest DIR run (renamed, not deleted) and continue it (--cont), so only those exercises run again.
# --system-prefix: text put at the start of aider's system prompt (aider system_prompt_prefix).
# --user-prefix: text put at the start of the last user message of every request (the task, or the test errors on try 2).
# --<aider_setting>: snake_case keys go into the generated model settings; aider ModelSettings fields
#   (use_temperature, reasoning_tag, system_prompt_prefix, ...) at top level, anything else (top_p, top_k, temperature, ...) under extra_params.
# DIR (default MODEL-FORMAT-MAXTOK) holds the log, model settings, requests.jsonl (each model request: params sent, ok/error, tokens), results.jsonl (each finished exercise), stats.yml and a results symlink; its name is the run name.
set -euo pipefail
MODE=; URL=http://127.0.0.1:8000/v1; MODEL=myai; KEY=dummy; FMT=whole; MAXTOK=96384; THREADS=4; RT=3600; OUT=; EXTRA=(); REDO=; SYSP=; USRP=; TOP=(); XP=()
SELF=$(realpath "$0"); RUNS=; OPTS=(); a=("$@"); i=0
while [ $i -lt ${#a[@]} ]; do case ${a[$i]} in --runs|--stats) i=$((i + 2));; --) break;; *) OPTS+=("${a[$i]}"); i=$((i + 1));; esac; done
AIDER_KEYS=" weak_model_name use_repo_map send_undo_reply lazy overeager reminder examples_as_sys_msg cache_control caches_by_default use_system_prompt use_temperature streaming editor_model_name editor_edit_format reasoning_tag remove_reasoning system_prompt_prefix accepts_settings "
while [ $# -gt 0 ]; do
  case $1 in
    --run|--show) MODE=${1#--}; shift;;
    --url) URL=$2; shift 2;;
    --model) MODEL=$2; shift 2;;
    --key) KEY=$2; shift 2;;
    --format) FMT=$2; shift 2;;
    --max-tokens) MAXTOK=$2; shift 2;;
    --threads) THREADS=$2; shift 2;;
    --request-timeout) RT=$2; shift 2;;
    --*_*|--temperature|--seed|--lazy|--overeager|--reminder|--streaming)
      k=${1#--}; if [[ $AIDER_KEYS == *" $k "* ]]; then TOP+=("  $k: $2"); else XP+=("    $k: $2"); fi; shift 2;;
    --stats) OUT=$2; shift 2;;
    --runs) RUNS=$2; shift 2;;
    --redo) REDO=$2; shift 2;;
    --system-prefix) SYSP=$2; shift 2;;
    --user-prefix) USRP=$2; shift 2;;
    --) shift; EXTRA=("$@"); break;;
    *) echo "unknown option: $1"; exit 1;;
  esac
done
[ -n "$MODE" ] || { echo "need --run or --show"; exit 1; }
case $FMT in whole|diff) ;; *) echo "--format must be whole or diff"; exit 1;; esac
[[ -z $RUNS || $RUNS =~ ^[1-9][0-9]*$ ]] || { echo "--runs must be a positive number"; exit 1; }
case $REDO in ""|exhausted|failed|crashed|errors|*/*) ;; *) echo "--redo must be exhausted, failed, crashed, errors or exercise names like rust/bob,go/forth"; exit 1;; esac
OUT=$(realpath -m "${OUT:-$MODEL-$FMT-$MAXTOK}"); NAME=$(basename "$OUT")
[[ $SYSP == @* ]] && SYSP=$(cat "${SYSP#@}")
[[ $USRP == @* ]] && USRP=$(cat "${USRP#@}")
mkdir -p "$OUT"
if [ "${RUNS:-1}" -gt 1 ] && [ "$MODE" = run ]; then
  [ -z "$REDO" ] || { echo "--redo works on one run of a series: --stats $OUT/$NAME-rK --redo $REDO"; exit 1; }
  XR=(); for x in "${EXTRA[@]:-}"; do case $x in --new|--cont) echo "note: $x ignored with --runs (existing runs continue, missing runs start)";; "") ;; *) XR+=("$x");; esac; done
  for i in $(seq "$RUNS"); do
    X=("${XR[@]}"); ls -d "$HOME/aider/tmp.benchmarks/"*--"$NAME-r$i"/ >/dev/null 2>&1 && X+=(--cont)
    echo "=== run $i of $RUNS: $OUT/$NAME-r$i"
    bash "$SELF" --stats "$OUT/$NAME-r$i" "${OPTS[@]}" -- "${X[@]}"
  done
  MODE=show
fi

cd ~
[ -d aider ] || git clone https://github.com/Aider-AI/aider.git
cd aider
mkdir -p tmp.benchmarks
[ -d tmp.benchmarks/polyglot-benchmark ] || git clone https://github.com/Aider-AI/polyglot-benchmark tmp.benchmarks/polyglot-benchmark
docker image inspect aider-benchmark >/dev/null 2>&1 || ./benchmark/docker_build.sh

SETUP="uv pip install --system -q -e .[dev] &&
  sed -i 's/\"\\.h\": \"c\",/\".h\": \"cpp\",/' \$(python3 -c 'import grep_ast.parsers as p; print(p.__file__)') &&
  python3 -c \"from grep_ast.parsers import filename_to_lang as f; assert f('x.h')=='cpp', f('x.h'); print('grep-ast .h -> cpp OK')\""
DOCKER=(docker run --rm -v "$PWD":/aider -v "$PWD/tmp.benchmarks":/benchmarks -w /aider
  -e AIDER_DOCKER=1 -e AIDER_BENCHMARK_DIR=/benchmarks)

series() {
  A=(); for s in "${SUBS[@]}"; do r=$(basename "$s"); R=$(ls -td tmp.benchmarks/*--"$r"/ 2>/dev/null | head -1); [ -z "$R" ] || A+=("$r=$R"); done
  [ ${#A[@]} -gt 0 ] || { echo "no results yet for the runs in $OUT"; exit 1; }
  PYTHONIOENCODING=utf-8 python3 - "${A[@]}" <<'EOF' | tee "$OUT/stats.yml"
import json, glob, sys, statistics, pathlib
T = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131,
     2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
runs = []
for arg in sys.argv[1:]:
    label, d = arg.split("=", 1)
    res = {}
    for f in glob.glob(d + "/*/exercises/practice/*/.aider.results.json"):
        try: o = json.load(open(f)).get("tests_outcomes") or []
        except Exception: continue
        p = pathlib.PurePath(f).parts
        res[p[-5] + "/" + p[-2]] = o
    runs.append((label, res))
N, full = len(runs), max(len(r) for _, r in runs)
def rate(res, i, lang=None):
    xs = [o for ex, o in res.items() if lang is None or ex.split("/")[0] == lang]
    return 100 * sum(any(o[:i]) for o in xs) / len(xs) if xs else float("nan")
def summary(v):
    m = statistics.mean(v)
    if len(v) < 2: return f"{m:5.1f}"
    sd = statistics.stdev(v); se = sd / len(v) ** 0.5; t = T[len(v) - 2] if len(v) - 2 < len(T) else 1.96
    return f"{m:5.1f} ± {se:.1f} SE   95% CI ±{t * se:.1f}   SD {sd:.2f}   range {min(v):.1f}-{max(v):.1f}"
print(f"{'run':<34} {'cases':>5} {'PR1':>6} {'PR2':>6}")
for label, res in runs:
    print(f"{label:<34} {len(res):5} {rate(res, 1):6.1f} {rate(res, 2):6.1f}" + ("  incomplete" if len(res) < full else ""))
print()
for i in (1, 2):
    print(f"pass_rate_{i}: {summary([rate(r, i) for _, r in runs])}   ({N} runs)")
print("\npass_rate_2 by language:")
for lang in sorted({ex.split("/")[0] for _, r in runs for ex in r}):
    print(f"  {lang:<12} {summary([rate(r, 2, lang) for _, r in runs])}")
common = set.intersection(*(set(r) for _, r in runs))
k = {ex: sum(any(r[ex]) for _, r in runs) for ex in common}
flaky = sorted((ex for ex in k if 0 < k[ex] < N), key=lambda ex: (k[ex], ex))
print(f"\nexercises in all {N} runs: {len(common)}   always pass: {sum(v == N for v in k.values())}   "
      f"always fail: {sum(v == 0 for v in k.values())}   flaky: {len(flaky)}")
line = " "
for item in (f"{ex} {k[ex]}/{N}" for ex in flaky):
    if len(line) + len(item) > 110: print(line); line = " "
    line += " " + item + " "
if flaky: print(line.rstrip())
if any(len(r) < full for _, r in runs):
    print(f"\nwarning: some runs have fewer than {full} exercises; rerun the same --runs command to finish them")
EOF
}

show() {
  mapfile -t SUBS < <(ls -d "$OUT/$NAME"-r[0-9]*/ 2>/dev/null | sort -V)
  if [ ${#SUBS[@]} -gt 0 ]; then series; return; fi
  RUN=$(ls -td tmp.benchmarks/*--"$NAME"/ 2>/dev/null | head -1)
  [ -n "$RUN" ] || { echo "no results for run $NAME in ~/aider/tmp.benchmarks"; exit 1; }
  ln -sfn "$PWD/${RUN%/}" "$OUT/results"
  { "${DOCKER[@]}" aider-benchmark bash -c "$SETUP >/dev/null && ./benchmark/benchmark.py --stats /benchmarks/$(basename "$RUN"); chown -R $(id -u):$(id -g) /benchmarks/$(basename "$RUN")"
    python3 - "$RUN" <<'EOF'
import json, glob, sys, collections, pathlib
rows = collections.defaultdict(list)
for f in sorted(glob.glob(sys.argv[1] + "/*/exercises/practice/*/.aider.results.json")):
    try: rows[pathlib.Path(f).relative_to(sys.argv[1]).parts[0]].append(json.load(open(f)))
    except Exception: pass
cols = f"{'Language':<12} | {'PR1':>5} | {'PR2':>5} | {'PN1':>5} | {'PN2':>5} | {'Cases':>5} | {'Asks':>5} | {'Malformed':>9} | {'P_Tok':>9} | {'C_Tok':>9} | {'Sec/Case':>8}"
print("\n" + cols + "\n" + "-" * len(cols))
def line(name, rs):
    n = len(rs)
    pn = [sum(any(r.get("tests_outcomes", [])[:i]) for r in rs) for i in (1, 2)]
    s = lambda k: sum(r.get(k, 0) or 0 for r in rs)
    print(f"{name:<12} | {100*pn[0]/n:5.1f} | {100*pn[1]/n:5.1f} | {pn[0]:5} | {pn[1]:5} | {n:5} | {s('num_user_asks'):5} | "
          f"{s('num_malformed_responses'):9} | {s('prompt_tokens'):9} | {s('completion_tokens'):9} | {s('duration')/n:8.1f}")
for lang in sorted(rows): line(lang, rows[lang])
if rows: line("TOTAL", sum(rows.values(), []))
EOF
    python3 - "$OUT/requests.jsonl" <<'EOF'
import json, sys, os, collections
if not os.path.exists(sys.argv[1]): sys.exit()
rs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ok = [r for r in rs if r.get("ok")]
print(f"\nrequests: {len(rs)}  ok: {len(ok)}  failed: {len(rs) - len(ok)}  (log: {sys.argv[1]})")
C = collections.Counter
for k, n in C(json.dumps(r.get("sent"), sort_keys=True) for r in rs).most_common(): print(f"  sent {n}x: {k}")
for k, n in C(r.get("finish") for r in ok).most_common(): print(f"  finish {k}: {n}")
for k, n in C(r.get("error_type", "") + ": " + r["error"] for r in rs if not r.get("ok")).most_common(10): print(f"  error {n}x: {k}")
EOF
  } | tee "$OUT/stats.yml"
}

if [ "$MODE" = run ]; then
  F=tmp.benchmarks/$NAME.model-settings.yml
  printf -- '- name: openai/%s\n  edit_format: %s\n  use_repo_map: true\n' "$MODEL" "$FMT" > "$F"
  [ -z "$SYSP" ] || TOP+=("  system_prompt_prefix: $(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$SYSP")")
  [ ${#TOP[@]} -eq 0 ] || printf '%s\n' "${TOP[@]}" >> "$F"
  [ "$MAXTOK" = 0 ] || XP=("    max_tokens: $MAXTOK" "${XP[@]}")
  XP+=("    timeout: $RT")
  [ ${#XP[@]} -eq 0 ] || { echo "  extra_params:"; printf '%s\n' "${XP[@]}"; } >> "$F"
  cp "$F" "$OUT/model-settings.yml"
  if [ -n "$USRP" ]; then printf '%s\n' "$USRP" > "$OUT/user-prefix.txt"; else rm -f "$OUT/user-prefix.txt"; fi
  if [ -n "$REDO" ]; then
    R=$(ls -td tmp.benchmarks/*--"$NAME"/ 2>/dev/null | head -1)
    [ -n "$R" ] || { echo "no run $NAME to redo"; exit 1; }
    "${DOCKER[@]}" -i aider-benchmark python3 - "/benchmarks/$(basename "$R")" "$REDO" <<'EOF'
import json, glob, os, sys, time, pathlib, textwrap
d, what = sys.argv[1], sys.argv[2]
tag, names = f".redo-{'list' if '/' in what else what}-{time.strftime('%m%d-%H%M%S')}", []
for f in glob.glob(d + "/*/exercises/practice/*/.aider.results.json"):
    r = json.load(open(f))
    p = pathlib.PurePath(f).parts; ex = p[-5] + "/" + p[-2]
    if ex in what.split(",") if "/" in what else {"exhausted": r.get("num_exhausted_context_windows"), "failed": not any(r.get("tests_outcomes") or []), "crashed": "exception" in r, "errors": (r.get("num_error_outputs") or r.get("num_malformed_responses")) and not any(r.get("tests_outcomes") or [])}[what]:
        names.append(ex)
        for x in (f, f.replace(".aider.results.json", ".aider.chat.history.md")):
            if os.path.exists(x): os.rename(x, x + tag)
print(f"redo {what}: {len(names)} set aside in {os.path.basename(d)} (renamed *{tag})")
if names: print(textwrap.fill(", ".join(sorted(names)), 110, initial_indent="  ", subsequent_indent="  "))
EOF
    [[ " ${EXTRA[*]:-} " == *" --cont "* ]] || EXTRA+=(--cont)
  fi
  LOG=$OUT/run-$(date +%F-%H-%M-%S).log; DIR=$NAME
  [[ " ${EXTRA[*]:-} " == *" --cont "* ]] && DIR=$(basename "$(ls -td tmp.benchmarks/*--"$NAME"/ | head -1)")
  CMD="./benchmark/benchmark.py $DIR --model openai/$MODEL --edit-format $FMT --read-model-settings /benchmarks/$NAME.model-settings.yml --threads $THREADS --exercises-dir polyglot-benchmark ${EXTRA[*]:-}"
  mkdir -p tmp.benchmarks/hook
  cat > tmp.benchmarks/hook/sitecustomize.py <<'EOF'
import sys
if sys.argv and sys.argv[0].endswith("benchmark.py") and "--stats" not in sys.argv:
    import json, os, re, threading, time, httpx
    import aider.llm
    _lock, _tl, _seen, _path = threading.Lock(), threading.local(), set(), "/out/requests.jsonl"
    _send = httpx.Client.send
    def send(self, request, **kw):
        try:
            b = json.loads(request.content)
            b.pop("messages", None); _tl.body = b
            k = json.dumps(b, sort_keys=True)
            if k not in _seen:
                _seen.add(k); say(c("2", "sent " + k))
        except Exception:
            pass
        return _send(self, request, **kw)
    httpx.Client.send = send
    def exercise():
        f = sys._getframe(2)
        while f:
            t = f.f_locals.get("testdir")
            if t is not None:
                p = str(t).rstrip("/").split("/")
                return p[-4] + "/" + p[-1] if len(p) >= 4 else str(t)
            f = f.f_back
    lazy = aider.llm.litellm
    _lx = []
    def exinfo(err):
        if not _lx:
            from aider.exceptions import LiteLLMExceptions
            _lx.append(LiteLLMExceptions())
        return _lx[0].get_ex_info(err)
    _C = os.environ.get("BENCH_COLOR") == "1"
    def c(code, s):
        return f"\033[{code}m{s}\033[0m" if _C else s
    def kt(n):
        n = n or 0
        return f"{n / 1000:.1f}k" if n >= 1000 else str(n)
    def say(msg):
        try:
            from tqdm import tqdm; tqdm.write(msg, file=sys.stderr)
        except Exception:
            print(msg, file=sys.stderr)
    def completion(**kw):
        lazy._load_litellm()
        up = os.environ.get("BENCH_USER_PREFIX")
        if up and kw.get("messages"):
            kw["messages"] = msgs = [dict(m) for m in kw["messages"]]
            for m in reversed(msgs):
                if m.get("role") == "user" and isinstance(m.get("content"), str):
                    m["content"] = up + "\n\n" + m["content"]
                    break
        _tl.body, t0 = None, time.time()
        rec = {"t": time.strftime("%H:%M:%S"), "ex": exercise(), "n_msgs": len(kw.get("messages") or [])}
        try:
            res = lazy._lazy_module.completion(**kw)
            u = getattr(res, "usage", None)
            rec.update(ok=True, finish=res.choices[0].finish_reason,
                       prompt_tokens=getattr(u, "prompt_tokens", None), completion_tokens=getattr(u, "completion_tokens", None))
            if getattr(_tl, "fails", 0):
                rec["after_failures"] = _tl.fails
                say(c("32", f"  ok {rec['ex']:<34} request succeeded after {_tl.fails} failed attempt(s)"))
            _tl.fails = 0
            return res
        except Exception as e:
            rec.update(ok=False, error=re.sub(r"(litellm\.)?\w*(Error|Exception|Timeout)(: | - )", "", f"{e}").strip() or repr(e), error_type=type(e).__name__)
            m = re.search(r"maximum context length is (\d+).*?requested (\d+) output.*?at least (\d+) input", str(e), re.S)
            short = f"context overflow: prompt {int(m[3]):,} + max_tokens {int(m[2]):,} > {int(m[1]):,}" if m else f"{rec['error_type']}: {rec['error'][:160]}"
            err = e
            if "maximum context length" in str(e) and type(e).__name__ != "ContextWindowExceededError":
                err = lazy._lazy_module.ContextWindowExceededError(message=str(e), model=kw.get("model"), llm_provider="openai")
            info = exinfo(err)
            _tl.fails = getattr(_tl, "fails", 0) + 1
            if info.name == "ContextWindowExceededError":
                action, col, _tl.fails = "-> try ends, counted as ctx", "31", 0
            elif info.retry:
                action, col = f"-> aider retries (retry {_tl.fails}, after {0.125 * 2 ** _tl.fails:g}s)", "33"
            elif info.name is None:
                action, col, _tl.fails = "-> unexpected error, try ends", "31", 0
            else:
                action, col, _tl.fails = "-> aider gives up on this request, try ends", "31", 0
            rec["action"] = action[3:]
            say(c(col, f"  !  {rec['ex']:<34} {short} {action}"))
            if err is not e:
                raise err from e
            raise
        finally:
            rec.update(sec=round(time.time() - t0, 1), sent=_tl.body)
            with _lock, open(_path, "a") as f:
                f.write(json.dumps(rec, default=str) + "\n")
    lazy.completion = completion
    import pathlib
    _wt, _n = pathlib.Path.write_text, [0, 0]
    def write_text(self, data, *a, **kw):
        r = _wt(self, data, *a, **kw)
        if self.name == ".aider.results.json":
            try:
                d, p = json.loads(data), self.parts
                o = d.get("tests_outcomes") or []
                ok = any(o)
                rec = {"t": time.strftime("%H:%M:%S"), "ex": p[-5] + "/" + p[-2], "pass": ok, "try": o.index(True) + 1 if ok else None,
                       "sec": round(d.get("duration") or 0), "prompt_tokens": d.get("prompt_tokens"), "completion_tokens": d.get("completion_tokens")}
                for k in ("num_error_outputs", "num_exhausted_context_windows", "num_malformed_responses", "test_timeouts", "num_user_asks"):
                    if d.get(k): rec[k.replace("num_", "")] = d[k]
                if "exception" in d: rec["crash"] = d["exception"].strip().splitlines()[-1][:200]
                with _lock:
                    _n[0] += 1; _n[1] += ok
                    with open("/out/results.jsonl", "a") as f: f.write(json.dumps(rec) + "\n")
                    lab = {"error_outputs": "errors", "exhausted_context_windows": "ctx", "malformed_responses": "malformed", "test_timeouts": "timeouts", "user_asks": "asks"}
                    extra = " ".join(f"{lab.get(k, k)}={v}" for k, v in rec.items() if k not in ("t", "ex", "pass", "try", "sec", "prompt_tokens", "completion_tokens"))
                    msg = (f"{c('32', 'PASS ' + str(rec['try'])) if ok else c('31', 'FAIL  ')}  {rec['ex']:<34} {rec['sec']:>5}s  in {kt(rec['prompt_tokens']):>6}  out {kt(rec['completion_tokens']):>6}"
                           f"  {c('2', f'{_n[1]}/{_n[0]} {100 * _n[1] / _n[0]:5.1f}%')}  {c('33', extra) if extra else ''}")
                say(msg)
            except Exception:
                pass
        return r
    pathlib.Path.write_text = write_text
EOF
  [ -t 2 ] && COLOR=1 || COLOR=0; B=; N=; [ $COLOR = 1 ] && B=$'\033[1m' N=$'\033[0m'
  echo "${B}settings${N}   $F"; sed 's/^/           /' "$F"
  [ -z "$USRP" ] || { echo "${B}user prefix${N}"; sed 's/^/           /' "$OUT/user-prefix.txt"; }
  echo "${B}benchmark${N}  $CMD"
  echo "${B}log${N}        tail -f $LOG"
  trap 'docker rm -f "aider-bench-$NAME" >/dev/null; exit 130' INT TERM
  "${DOCKER[@]}" --name "aider-bench-$NAME" --memory=12g --memory-swap=12g -e OPENAI_API_BASE="$URL" -e OPENAI_API_KEY="$KEY" \
    -v "$OUT":/out -e PYTHONPATH=/benchmarks/hook -e BENCH_COLOR=$COLOR -e BENCH_USER_PREFIX="$USRP" \
    aider-benchmark bash -c "$SETUP && echo '--- in docker: $CMD' && { $CMD; rc=\$?; chown $(id -u):$(id -g) /out/requests.jsonl /out/results.jsonl 2>/dev/null; exit \$rc; }" \
    >"$LOG" 2> >(grep --line-buffered -v 'Input is not a terminal' | tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG") >&2) \
    || { echo "benchmark failed, last lines of $LOG:"; tail -20 "$LOG"; exit 1; }
  grep -E "^(Prior runs|ERROR: |No exercise|Warning: benchmarking)" "$LOG" && exit 1
fi
show

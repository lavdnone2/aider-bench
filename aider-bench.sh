#!/usr/bin/env bash
# usage: ./aider-bench.sh --run [--url URL] [--model NAME] [--key KEY] [--format whole|diff] [--max-tokens N (0 = let server use remaining context)] [--threads N] [--request-timeout SEC] [--stats DIR] [--redo exhausted|failed|crashed|errors|LANG/EXERCISE,...] [--system-prefix TEXT|@FILE] [--user-prefix TEXT|@FILE] [--<aider_setting> V ...] [-- extra benchmark.py args]
#        ./aider-bench.sh --show [--stats DIR]
# --redo: (errors = failed exercises that had error outputs or malformed replies) set aside matching results of the latest DIR run (renamed, not deleted) and continue it (--cont), so only those exercises run again.
# --system-prefix: text put at the start of aider's system prompt (aider system_prompt_prefix).
# --user-prefix: text put at the start of the last user message of every request (the task, or the test errors on try 2).
# --<aider_setting>: snake_case keys go into the generated model settings; aider ModelSettings fields
#   (use_temperature, reasoning_tag, system_prompt_prefix, ...) at top level, anything else (top_p, top_k, temperature, ...) under extra_params.
# DIR (default MODEL-FORMAT-MAXTOK) holds the log, model settings, requests.jsonl (each model request: params sent, ok/error, tokens), results.jsonl (each finished exercise), stats.yml and a results symlink; its name is the run name.
set -euo pipefail
MODE=; URL=http://127.0.0.1:8000/v1; MODEL=myai; KEY=dummy; FMT=whole; MAXTOK=96384; THREADS=4; RT=3600; OUT=; EXTRA=(); REDO=; SYSP=; USRP=; TOP=(); XP=()
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
    --redo) REDO=$2; shift 2;;
    --system-prefix) SYSP=$2; shift 2;;
    --user-prefix) USRP=$2; shift 2;;
    --) shift; EXTRA=("$@"); break;;
    *) echo "unknown option: $1"; exit 1;;
  esac
done
[ -n "$MODE" ] || { echo "need --run or --show"; exit 1; }
case $FMT in whole|diff) ;; *) echo "--format must be whole or diff"; exit 1;; esac
case $REDO in ""|exhausted|failed|crashed|errors|*/*) ;; *) echo "--redo must be exhausted, failed, crashed, errors or exercise names like rust/bob,go/forth"; exit 1;; esac
OUT=$(realpath -m "${OUT:-$MODEL-$FMT-$MAXTOK}"); NAME=$(basename "$OUT")
[[ $SYSP == @* ]] && SYSP=$(cat "${SYSP#@}")
[[ $USRP == @* ]] && USRP=$(cat "${USRP#@}")
mkdir -p "$OUT"

cd ~
[ -d aider ] || git clone https://github.com/Aider-AI/aider.git
cd aider
mkdir -p tmp.benchmarks
[ -d tmp.benchmarks/polyglot-benchmark ] || git clone https://github.com/Aider-AI/polyglot-benchmark tmp.benchmarks/polyglot-benchmark
docker image inspect aider-benchmark >/dev/null 2>&1 || ./benchmark/docker_build.sh

SETUP="uv pip install --system -q -e .[dev] &&
  uv pip install --system -q --no-deps --reinstall 'git+https://github.com/fernandaspets/grep-ast@fix/h-header-cpp-grammar' &&
  python3 -c \"from grep_ast.parsers import filename_to_lang as f; assert f('x.h')=='cpp', f('x.h'); print('grep-ast PR24 OK')\""
DOCKER=(docker run --rm -v "$PWD":/aider -v "$PWD/tmp.benchmarks":/benchmarks -w /aider
  -e AIDER_DOCKER=1 -e AIDER_BENCHMARK_DIR=/benchmarks)

show() {
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
            return res
        except Exception as e:
            rec.update(ok=False, error=re.sub(r"(litellm\.)?\w+(Error|Exception)(: | - )", "", f"{e}").strip() or repr(e), error_type=type(e).__name__)
            m = re.search(r"maximum context length is (\d+).*?requested (\d+) output.*?at least (\d+) input", str(e), re.S)
            short = f"context overflow: prompt {int(m[3]):,} + max_tokens {int(m[2]):,} > {int(m[1]):,}" if m else f"{rec['error_type']}: {rec['error'][:160]}"
            say(c("33", f"  !  {rec['ex']:<34} {short}"))
            if "maximum context length" in str(e) and type(e).__name__ != "ContextWindowExceededError":
                raise lazy._lazy_module.ContextWindowExceededError(message=str(e), model=kw.get("model"), llm_provider="openai") from e
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

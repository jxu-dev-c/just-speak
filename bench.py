"""Latency benchmark: Inception Mercury 3 vs Groq models for speech-rewrite.

Usage: python3 bench.py [runs_per_prompt]
Reads INCEPTION_API_KEY and GROQ_API_KEY from .env.
"""
import json
import os
import statistics
import sys
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).parent
for line in (ROOT / ".env").read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

PROVIDERS = {
    "inception": ("https://api.inceptionlabs.ai/v1/chat/completions", os.environ["INCEPTION_API_KEY"]),
    "groq": ("https://api.groq.com/openai/v1/chat/completions", os.environ["GROQ_API_KEY"]),
}

# (label, provider, model, extra body params)
CONFIGS = [
    ("mercury-3 (instant)", "inception", "mercury-3", {"reasoning_effort": "instant"}),
    ("mercury-3 (default)", "inception", "mercury-3", {}),
    ("groq gpt-oss-20b (low)", "groq", "openai/gpt-oss-20b", {"reasoning_effort": "low"}),
    ("groq gpt-oss-120b (low)", "groq", "openai/gpt-oss-120b", {"reasoning_effort": "low"}),
    ("groq qwen3.8-27b (none)", "groq", "qwen/qwen3.8-27b", {"reasoning_effort": "none"}),
]

SYSTEM = (
    "You rewrite dictated speech into clean, well-formed written text. "
    "Fix grammar, remove filler words and false starts, keep the speaker's meaning. "
    "Output only the rewritten text, nothing else."
)

PROMPTS = {
    "short": "um so me and him went to the uh the store yesterday and we buyed some milk",
    "medium": (
        "okay so basically what I'm trying to say is that the meeting tomorrow, uh, it's gonna be moved "
        "to three pm instead of two because, like, Sarah can't make it at two, and also we need to, um, "
        "make sure everyone brings their laptops because we're gonna be doing the demo of the new feature "
        "and stuff, so yeah just let everybody know"
    ),
    "long": (
        "alright so here's the problem I need help with, a train leaves the station at uh nine in the morning "
        "going like sixty miles an hour, and then another train, the second one, it leaves the same station "
        "at ten going eighty miles an hour in the same direction, and the question is basically when does the "
        "second train catch up to the first one and how far from the station are they when that happens, "
        "and um also I think it asks what if the first train had left at eight thirty instead, like how does "
        "that change the answer, so can you rewrite that as a clean word problem that a student could read, "
        "with the numbers clearly stated and the two questions separated out"
    ),
}


def run_once(client: httpx.Client, cfg, prompt: str) -> dict:
    label, provider, model, extra = cfg
    url, key = PROVIDERS[provider]
    body = {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
        "stream": True,
        "stream_options": {"include_usage": True},
        "max_tokens": 1024,
        "temperature": 0,
        **extra,
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    t0 = time.perf_counter()
    ttft = None
    text = []
    usage = None
    with client.stream("POST", url, json=body, headers=headers, timeout=60) as r:
        if r.status_code != 200:
            r.read()
            raise RuntimeError(f"{label}: HTTP {r.status_code} {r.text[:300]}")
        for line in r.iter_lines():
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            for ch in chunk.get("choices") or []:
                content = (ch.get("delta") or {}).get("content")
                if content:
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    text.append(content)
            u = chunk.get("usage") or (chunk.get("x_groq") or {}).get("usage")
            if u:
                usage = u
    total = time.perf_counter() - t0
    completion = (usage or {}).get("completion_tokens", 0)
    reasoning = ((usage or {}).get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
    visible = completion - reasoning
    gen_time = total - (ttft or total)
    return {
        "ttft": ttft or total,
        "total": total,
        "completion_tokens": completion,
        "visible_tokens": visible,
        "reasoning_tokens": reasoning,
        # streaming speed after first token; only meaningful when >1 chunk arrives
        "stream_tps": visible / gen_time if gen_time > 0.005 else None,
        # what the user experiences: all completion tokens over the whole request
        "e2e_tps": completion / total if total else 0,
        "text": "".join(text),
    }


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))]


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    clients = {p: httpx.Client(http2=False) for p in PROVIDERS}
    results = {cfg[0]: [] for cfg in CONFIGS}
    samples = {}

    # warm up connections (TLS + DNS) so we measure model latency, as a long-lived app would
    for cfg in CONFIGS:
        run_once(clients[cfg[1]], cfg, PROMPTS["short"])

    # round-robin across configs so network drift affects all equally
    for i in range(runs):
        for pname, prompt in PROMPTS.items():
            for cfg in CONFIGS:
                try:
                    r = run_once(clients[cfg[1]], cfg, prompt)
                except Exception as e:
                    print("ERR", e, file=sys.stderr)
                    continue
                r["prompt"] = pname
                results[cfg[0]].append(r)
                samples.setdefault((cfg[0], pname), r["text"])
        print(f"round {i + 1}/{runs} done", file=sys.stderr)

    # cold-start sample: new connection per request (first request after app launch)
    cold = {cfg[0]: [] for cfg in CONFIGS}
    for _ in range(3):
        for cfg in CONFIGS:
            with httpx.Client() as c:
                cold[cfg[0]].append(run_once(c, cfg, PROMPTS["short"])["ttft"])

    out = []
    hdr = f"{'config':26} {'n':>3} {'TTFT med':>9} {'TTFT p90':>9} {'total med':>10} {'total p90':>10} {'stream tok/s':>12} {'e2e tok/s':>10} {'reason tok':>10} {'cold TTFT':>10}"
    out.append(hdr)
    out.append("-" * len(hdr))
    summary = {}
    for label, rs in results.items():
        if not rs:
            continue
        ttft = [r["ttft"] for r in rs]
        tot = [r["total"] for r in rs]
        stps = [r["stream_tps"] for r in rs if r["stream_tps"]]
        etps = [r["e2e_tps"] for r in rs]
        rt = [r["reasoning_tokens"] for r in rs]
        s = {
            "n": len(rs),
            "ttft_med": statistics.median(ttft), "ttft_p90": pct(ttft, 0.9), "ttft_mean": statistics.mean(ttft),
            "total_med": statistics.median(tot), "total_p90": pct(tot, 0.9), "total_mean": statistics.mean(tot),
            "stream_tps_med": statistics.median(stps) if stps else None,
            "e2e_tps_med": statistics.median(etps),
            "reasoning_mean": statistics.mean(rt),
            "cold_ttft_med": statistics.median(cold[label]),
            "by_prompt": {
                p: {
                    "ttft_med": statistics.median([r["ttft"] for r in rs if r["prompt"] == p]),
                    "total_med": statistics.median([r["total"] for r in rs if r["prompt"] == p]),
                    "tokens_med": statistics.median([r["completion_tokens"] for r in rs if r["prompt"] == p]),
                }
                for p in PROMPTS
            },
        }
        summary[label] = s
        stps_s = f"{s['stream_tps_med']:.0f}" if s["stream_tps_med"] else "n/a"
        out.append(
            f"{label:26} {s['n']:>3} {s['ttft_med']*1000:>7.0f}ms {s['ttft_p90']*1000:>7.0f}ms "
            f"{s['total_med']*1000:>8.0f}ms {s['total_p90']*1000:>8.0f}ms {stps_s:>12} {s['e2e_tps_med']:>10.0f} "
            f"{s['reasoning_mean']:>10.1f} {s['cold_ttft_med']*1000:>8.0f}ms"
        )
    out.append("")
    out.append("Median total latency by prompt (ms):")
    out.append(f"{'config':26} " + " ".join(f"{p:>14}" for p in PROMPTS))
    for label, s in summary.items():
        out.append(f"{label:26} " + " ".join(
            f"{s['by_prompt'][p]['total_med']*1000:>8.0f} ({s['by_prompt'][p]['tokens_med']:.0f}t)" for p in PROMPTS))
    report = "\n".join(out)
    print(report)

    (ROOT / "bench_results.json").write_text(json.dumps(
        {"summary": summary, "samples": {f"{k[0]} | {k[1]}": v for k, v in samples.items()}}, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""OpenVox sidecar: a long-lived NDJSON process wrapping one ASR engine at a
time (Moonshine offline, Nemotron streaming). See docs/superpowers/specs/
2026-08-31-openvox-design.md, section "Sidecar protocol", for the wire
format this file implements.

Ops in on stdin, one JSON object per line:
  {"op":"load","engine":"moonshine"|"nemotron"}
  {"op":"transcribe","pcm":"<b64 float32 LE, 16 kHz mono>"}
  {"op":"stream","pcm":"<b64 float32 LE, 16 kHz mono, one 160 ms chunk>"}
  {"op":"finalize"}
  {"op":"ping"}

Events out on stdout, one JSON object per line, flushed after every write:
  {"ev":"progress","stage":"download"|"load","pct":0-100}
  {"ev":"ready","engine":...}
  {"ev":"partial","text":"<full transcript so far>"}
  {"ev":"final","text":...}
  {"ev":"error","message":...,"code":?}
  {"ev":"pong"}

stderr carries free-form logs. The process exits cleanly when stdin closes.
"""

from __future__ import annotations

import base64
import json
import sys

import numpy as np

from engines import MissingStreamingDeps, MoonshineEngine, NemotronEngine, SAMPLE_RATE

_ENGINES = {"moonshine": MoonshineEngine, "nemotron": NemotronEngine}


def _emit(ev: str, **fields) -> None:
    print(json.dumps({"ev": ev, **fields}), flush=True)


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _decode_pcm(b64: str) -> np.ndarray:
    return np.frombuffer(base64.b64decode(b64), dtype="<f4")


class Sidecar:
    def __init__(self) -> None:
        self.engine = None
        self.engine_name: str | None = None

    def op_load(self, msg: dict) -> None:
        name = msg.get("engine")
        if name not in _ENGINES:
            raise ValueError(f"unknown engine {name!r}")
        if name == self.engine_name:
            # A duplicate load must not run load-then-swap: two copies of
            # nemotron would briefly need ~7 GB on an 8 GB machine.
            _emit("ready", engine=name)
            return

        engine = _ENGINES[name]()
        try:
            engine.load(on_progress=lambda stage, pct: _emit("progress", stage=stage, pct=pct))
        except MissingStreamingDeps as exc:
            # Deliberately do NOT touch self.engine here: a failed load of
            # a different engine must leave the currently loaded one (if
            # any) usable. See design doc's lazy-provisioning section.
            _emit("error", code="missing-streaming-deps", message=str(exc))
            return
        engine.warmup()

        # Only swap now that the new engine is fully loaded and warm: the
        # old engine stays serviceable for the entire duration of the new
        # one's (possibly slow, possibly failing) load.
        if self.engine is not None:
            _log(f"unloading {self.engine_name}")
            self.engine.unload()
        self.engine = engine
        self.engine_name = name
        _emit("ready", engine=name)

    def op_transcribe(self, msg: dict) -> None:
        if self.engine is None:
            raise RuntimeError("no engine loaded")
        audio = _decode_pcm(msg["pcm"])
        text = self.engine.transcribe(audio)
        _emit("final", text=text)

    def op_stream(self, msg: dict) -> None:
        if self.engine is None:
            raise RuntimeError("no engine loaded")
        if not hasattr(self.engine, "stream"):
            raise RuntimeError(f"{self.engine_name} does not support streaming")
        chunk = _decode_pcm(msg["pcm"])
        text = self.engine.stream(chunk)
        if text is not None:
            _emit("partial", text=text)

    def op_finalize(self, _msg: dict) -> None:
        if self.engine is not None and hasattr(self.engine, "finalize"):
            text = self.engine.finalize()
        else:
            text = ""
        _emit("final", text=text)

    def op_ping(self, _msg: dict) -> None:
        _emit("pong")

    def dispatch(self, msg: dict) -> None:
        op = msg.get("op")
        handler = getattr(self, f"op_{op}", None)
        if handler is None:
            raise ValueError(f"unknown op {op!r}")
        handler(msg)

    def run(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                self.dispatch(msg)
            except Exception as exc:
                _log(f"error handling {line!r}: {exc}")
                _emit("error", message=str(exc))
        # stdin closed: exit cleanly (app restarts the sidecar if needed).


# --------------------------------------------------------------- self-check


def _selfcheck() -> None:
    import os
    import subprocess
    import tempfile
    import time
    import wave

    def load_wav(path: str) -> np.ndarray:
        with wave.open(path, "rb") as w:
            assert w.getnchannels() == 1, f"expected mono, got {w.getnchannels()} channels"
            assert w.getsampwidth() == 2, f"expected 16-bit PCM, got {w.getsampwidth() * 8}-bit"
            assert w.getframerate() == SAMPLE_RATE, f"expected {SAMPLE_RATE} Hz, got {w.getframerate()}"
            frames = w.readframes(w.getnframes())
        return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0

    def chunk_160ms(audio: np.ndarray) -> list[np.ndarray]:
        n = SAMPLE_RATE * 160 // 1000  # 2560 samples
        out = []
        for start in range(0, len(audio), n):
            piece = audio[start:start + n]
            if len(piece) < n:
                piece = np.pad(piece, (0, n - len(piece)))
            out.append(np.ascontiguousarray(piece, dtype=np.float32))
        return out

    def to_b64(audio: np.ndarray) -> str:
        return base64.b64encode(np.ascontiguousarray(audio, dtype="<f4").tobytes()).decode("ascii")

    class Client:
        """Drives the real NDJSON protocol over pipes against a child
        sidecar process. This is the whole point of the self-check: it
        never calls engine methods directly, only the same wire protocol
        SidecarClient (Swift) speaks.
        """

        def __init__(self) -> None:
            self.proc = subprocess.Popen(
                [sys.executable, os.path.abspath(__file__)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=None, text=True, bufsize=1,
            )

        def send(self, **msg) -> None:
            self.proc.stdin.write(json.dumps(msg) + "\n")
            self.proc.stdin.flush()

        def recv_until(self, *evs: str):
            """Read lines until one whose "ev" is in evs. Returns
            (that_event, all_events_seen_including_it) -- callers scan the
            list for e.g. "partial" events that may have preceded it.
            """
            seen = []
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    raise RuntimeError("sidecar exited unexpectedly")
                m = json.loads(line)
                seen.append(m)
                if m.get("ev") in evs:
                    return m, seen

        def close(self) -> None:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)

    sentence = "The quick brown fox jumps over the lazy dog and then it runs across the field"
    fd, wav_path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        t0 = time.perf_counter()
        subprocess.run(["say", "-o", wav_path, "--data-format=LEI16@16000", sentence], check=True)
        clip = load_wav(wav_path)
        print(f"synth clip: {len(clip) / SAMPLE_RATE:.2f}s ({time.perf_counter() - t0:.2f}s to synthesize)")

        client = Client()

        # ---- moonshine: load + offline transcribe --------------------------
        t0 = time.perf_counter()
        client.send(op="load", engine="moonshine")
        ev, _ = client.recv_until("ready", "error")
        assert ev["ev"] == "ready", ev
        print(f"moonshine load(): {time.perf_counter() - t0:.2f}s")

        t0 = time.perf_counter()
        client.send(op="transcribe", pcm=to_b64(clip))
        ev, _ = client.recv_until("final", "error")
        assert ev["ev"] == "final", ev
        offline_text = ev["text"]
        print(f"moonshine transcribe(): {time.perf_counter() - t0:.2f}s -> {offline_text!r}")
        assert isinstance(offline_text, str) and len(offline_text.split()) >= 3, offline_text

        # ---- nemotron: load (also proves engine switching/unload) ----------
        t0 = time.perf_counter()
        client.send(op="load", engine="nemotron")
        ev, _ = client.recv_until("ready", "error")
        load_s = time.perf_counter() - t0

        if ev["ev"] == "error":
            # requirements-streaming.txt is not installed in this
            # interpreter: confirm the sidecar reports the documented code
            # and stays healthy (moonshine still usable) instead of dying.
            assert ev.get("code") == "missing-streaming-deps", ev
            print(f"nemotron load(): {load_s:.2f}s -> reported missing-streaming-deps (expected, torch absent)")

            client.send(op="ping")
            ev2, _ = client.recv_until("pong", "error")
            assert ev2["ev"] == "pong", ev2

            client.send(op="transcribe", pcm=to_b64(clip))
            ev3, _ = client.recv_until("final", "error")
            assert ev3["ev"] == "final" and ev3["text"], ev3
            print("sidecar stayed healthy after missing-deps error (ping + moonshine transcribe still work)")
            print("skipping streaming checks: torch/transformers not installed under this interpreter")
        else:
            assert ev["ev"] == "ready", ev
            print(f"nemotron load(): {load_s:.2f}s")

            t0 = time.perf_counter()
            partials: list[tuple[int, str]] = []
            for i, piece in enumerate(chunk_160ms(clip)):
                client.send(op="stream", pcm=to_b64(piece))
                # A ping after every chunk is the sync barrier: ops are
                # processed strictly in order on one stdin loop, so pong
                # cannot arrive before this chunk's partial (if any) does.
                client.send(op="ping")
                ev, seen = client.recv_until("pong", "error")
                assert ev["ev"] == "pong", (ev, seen)
                for m in seen:
                    if m.get("ev") == "partial":
                        partials.append((i, m["text"]))

            client.send(op="finalize")
            ev, _ = client.recv_until("final", "error")
            assert ev["ev"] == "final", ev
            final_text = ev["text"]
            print(f"nemotron streaming: {time.perf_counter() - t0:.2f}s")

            for i, text in partials:
                print(f"  partial[{i}] = {text!r}")
            print(f"nemotron final: {final_text!r}")

            texts = [t for _, t in partials]
            assert len(set(texts)) >= 2, f"expected >=2 distinct partials, got {set(texts)}"
            for prev, nxt in zip(texts, texts[1:]):
                assert nxt.startswith(prev), f"partial not append-only: {prev!r} -> {nxt!r}"
            assert isinstance(final_text, str) and final_text, "empty final transcript"

        client.close()
        print("selfcheck ok")
    finally:
        os.unlink(wav_path)


def main() -> None:
    if "--selfcheck" in sys.argv:
        _selfcheck()
        return
    Sidecar().run()


if __name__ == "__main__":
    main()

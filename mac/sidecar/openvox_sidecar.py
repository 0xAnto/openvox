#!/usr/bin/env python3
"""OpenVox sidecar: a long-lived NDJSON process wrapping one ASR engine at a
time (Moonshine offline, Nemotron streaming). See docs/superpowers/specs/
2026-08-31-openvox-design.md, section "Sidecar protocol", for the wire
format this file implements.

Ops in on stdin, one JSON object per line:
  {"op":"load","engine":"moonshine"|"nemotron","variant":?"medium"|"small"|"tiny"}
  {"op":"transcribe","pcm":"<b64 float32 LE, 16 kHz mono>"}
  {"op":"stream","pcm":"<b64 float32 LE, 16 kHz mono, one 160 ms chunk>"}
  {"op":"finalize"}
  {"op":"ping"}

Events out on stdout, one JSON object per line, flushed after every write:
  {"ev":"progress","stage":"download"|"load","pct":0-100}
  {"ev":"ready","engine":...,"variant":?...}
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

from engines import (MissingStreamingDeps, MOONSHINE_FALLBACK_VARIANT, MoonshineEngine,
                     NemotronEngine, SAMPLE_RATE)

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
        self.engine_key: tuple | None = None

    def op_load(self, msg: dict) -> None:
        name = msg.get("engine")
        if name not in _ENGINES:
            raise ValueError(f"unknown engine {name!r}")
        # Only moonshine has size variants. MoonshineEngine rejects a name
        # that is not one of its known folders.
        variant = msg.get("variant") if name == "moonshine" else None
        key = (name, variant)
        if key == self.engine_key:
            # A duplicate load must not run load-then-swap: two copies of
            # nemotron would briefly need ~7 GB on an 8 GB machine. The
            # variant belongs in this test too, or switching size reports
            # ready without loading the new graphs.
            _emit("ready", engine=name, variant=variant)
            return

        # Try the size that was asked for, then fall back to the portable
        # one. small and tiny ship ORT-format graphs, which are tied to the
        # onnxruntime that wrote them; medium ships .onnx, which is not.
        # A machine whose onnxruntime cannot read the ORT files therefore
        # still ends up with a working engine, with no step for the user.
        # An unknown variant name still raises: that is an app bug, and
        # hiding it behind a fallback would keep it hidden. Only a genuine
        # load failure falls back.
        attempts = [variant]
        if name == "moonshine" and variant != MOONSHINE_FALLBACK_VARIANT:
            attempts.append(MOONSHINE_FALLBACK_VARIANT)

        # Construct every candidate BEFORE unloading anything. The engine
        # constructor is what validates the variant name, and unloading
        # first would answer a bad name by throwing away a working engine.
        candidates = [
            _ENGINES[name](a) if a is not None else _ENGINES[name]()
            for a in attempts
        ]

        # Changing size inside one engine: drop the loaded graphs before
        # building the new ones, so the process never holds two models at
        # once. Loading medium then swapping to small peaked at 1423 MB;
        # unloading first keeps the peak at whichever single model is
        # larger. Nothing is lost by it: beginLoad clears sidecarReady, so
        # the app refuses to dictate for the whole switch either way. A
        # cross-engine load keeps the load-then-swap below, which is what
        # protects the missing-deps case from unloading a working engine
        # for nothing.
        if name == self.engine_name and self.engine is not None:
            _log(f"unloading {self.engine_name} before reloading at {variant}")
            try:
                self.engine.unload()
            except Exception as exc:
                _log(f"unload before reload failed (continuing): {exc}")
            self.engine, self.engine_name, self.engine_key = None, None, None

        engine = None
        for index, (attempt, candidate) in enumerate(zip(attempts, candidates)):
            try:
                candidate.load(on_progress=lambda stage, pct: _emit("progress", stage=stage, pct=pct))
                candidate.warmup()
            except MissingStreamingDeps as exc:
                # Deliberately do NOT touch self.engine here: a failed load of
                # a different engine must leave the currently loaded one (if
                # any) usable. See design doc's lazy-provisioning section.
                _emit("error", code="missing-streaming-deps", message=str(exc))
                return
            except Exception as exc:
                _log(f"{name} failed to load at {attempt!r}: {exc}")
                if index == len(attempts) - 1:
                    raise
                _log(f"falling back to {attempts[index + 1]!r}")
                continue
            engine, variant = candidate, attempt
            break

        # The reported variant is the one that loaded, not the one asked
        # for, so the app can correct its picker after a fallback.
        key = (name, variant)

        # Only swap now that the new engine is fully loaded and warm: the
        # old engine stays serviceable for the entire duration of the new
        # one's (possibly slow, possibly failing) load. Swap references
        # BEFORE unloading so a failing unload can never leave the sidecar
        # pointing at a half-dead engine.
        old, old_name = self.engine, self.engine_name
        self.engine, self.engine_name, self.engine_key = engine, name, key
        if old is not None:
            _log(f"unloading {old_name}")
            try:
                old.unload()
            except Exception as exc:
                _log(f"unload of {old_name} failed (continuing): {exc}")
        _emit("ready", engine=name, variant=variant)

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
        # One 160 ms chunk (2560 samples); the tail at key-up may be short.
        if not 0 < len(chunk) <= 2560:
            raise ValueError(f"stream chunk must be 1..2560 samples, got {len(chunk)}")
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
                _log(f"error handling {line[:200]!r}: {exc}")
                # A failed op must not leak a half-done utterance into the
                # next one: abort any in-flight stream state.
                try:
                    if self.engine is not None and hasattr(self.engine, "abort"):
                        self.engine.abort()
                except Exception as abort_exc:
                    _log(f"abort after error failed: {abort_exc}")
                _emit("error", message=str(exc))
        # stdin closed: exit cleanly (app restarts the sidecar if needed).


# --------------------------------------------------------------- self-check


def _check_fallback() -> None:
    """A real ORT-format size cannot be made to fail on demand, so drive
    op_load against a stub engine that refuses everything except medium.
    This is the only check that reaches the fallback branch."""
    global _emit, _ENGINES

    tried: list = []

    class StubEngine:
        def __init__(self, variant):
            self.variant = variant

        def load(self, on_progress=None):
            tried.append(self.variant)
            if self.variant != MOONSHINE_FALLBACK_VARIANT:
                raise RuntimeError(f"pretend the {self.variant} graphs will not open")

        def warmup(self):
            pass

        def unload(self):
            pass

    saved_emit, saved_engines = _emit, _ENGINES
    events: list = []
    _ENGINES = dict(saved_engines, moonshine=StubEngine)
    _emit = lambda ev, **fields: events.append({"ev": ev, **fields})  # noqa: E731
    try:
        sc = Sidecar()
        sc.op_load({"op": "load", "engine": "moonshine", "variant": "tiny"})
        assert tried == ["tiny", "medium"], f"expected a fallback, tried {tried}"
        assert events[-1] == {"ev": "ready", "engine": "moonshine", "variant": "medium"}, events
        assert sc.engine_key == ("moonshine", "medium"), sc.engine_key

        # The app follows the reported size, so a duplicate load of what
        # actually loaded must short-circuit rather than reload.
        tried.clear()
        sc.op_load({"op": "load", "engine": "moonshine", "variant": "medium"})
        assert tried == [], f"a duplicate load must short-circuit, tried {tried}"
    finally:
        _emit, _ENGINES = saved_emit, saved_engines
    print("fallback ok (tiny refused -> medium loaded and reported)")


def _selfcheck() -> None:
    _check_fallback()

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

        # ---- moonshine: the size variants -----------------------------
        # tiny is the smallest download, so the check pays the least for
        # proving that a variant switch reloads instead of short-circuiting.
        client.send(op="load", engine="moonshine", variant="tiny")
        ev, _ = client.recv_until("ready", "error")
        assert ev["ev"] == "ready", ev
        assert ev.get("variant") == "tiny", f"switch to tiny did not take: {ev}"

        client.send(op="transcribe", pcm=to_b64(clip))
        ev, _ = client.recv_until("final", "error")
        assert ev["ev"] == "final" and len(ev["text"].split()) >= 3, ev
        print(f"moonshine tiny transcribe() -> {ev['text']!r}")

        client.send(op="load", engine="moonshine", variant="medium")
        ev, _ = client.recv_until("ready", "error")
        assert ev.get("variant") == "medium", f"switch back to medium did not take: {ev}"

        # An unknown size must be refused, and must leave the loaded engine
        # usable rather than killing the sidecar.
        client.send(op="load", engine="moonshine", variant="enormous")
        ev, _ = client.recv_until("error", "ready")
        assert ev["ev"] == "error", f"expected a refusal, got {ev}"
        client.send(op="transcribe", pcm=to_b64(clip))
        ev, _ = client.recv_until("final", "error")
        assert ev["ev"] == "final" and ev["text"], ev
        print("variant checks ok (tiny/medium switch, bad variant refused)")

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

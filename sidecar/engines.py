"""ASR engines for the OpenVox sidecar.

Ports of the proven adapters in
`/Users/kana/Documents/Apps/asr-benchmark/adapters/{moonshine_onnx,nemotron}.py`,
with the benchmark-only plumbing (describe(), disk/precision inspection,
multi-chunk-size support, CoreML) removed. Comments kept from those adapters
explain a real constraint the code cannot show by itself (an ONNX graph with
no KV cache, a Metal thread-affinity crash) -- they are not this file's own
design notes.

Dependency split (see the design doc's "Python runtime and lazy
provisioning" section): Fast/Offline (Moonshine) needs only
requirements-base.txt (numpy, huggingface_hub, onnxruntime, tokenizers).
Streaming (Nemotron) needs torch/transformers on top of that
(requirements-streaming.txt), which is a multi-GB install most users never
opt into. So this module never imports torch or transformers at module
level -- NemotronEngine.load() imports them lazily and raises
MissingStreamingDeps if they are not installed, leaving Moonshine fully
usable either way.
"""

from __future__ import annotations

import gc
import json
import os
import queue
import threading

import numpy as np
import onnxruntime as ort

SAMPLE_RATE = 16_000


class MissingStreamingDeps(Exception):
    """torch/transformers are not installed. Kept distinct from other load
    failures so the sidecar can reply with code "missing-streaming-deps"
    and keep serving Moonshine (see design doc)."""


def _download_kwargs(on_progress) -> dict:
    """tqdm_class hook so `snapshot_download()` reports real progress via
    on_progress("download", pct). Both models are already cached on dev
    machines, so this path is normally a no-op -- it only has to not crash.
    Omitted entirely when nobody wants progress events.
    """
    if on_progress is None:
        return {}
    from tqdm.auto import tqdm as base_tqdm

    class _ProgressTqdm(base_tqdm):
        def update(self, n=1):
            super().update(n)
            if self.total:
                pct = max(0, min(100, int(100 * self.n / self.total)))
                on_progress("download", pct)

    return {"tqdm_class": _ProgressTqdm}


# ==========================================================================
# Moonshine (ONNX, CPUExecutionProvider only, offline transcribe() only --
# see module docstring in the reference adapter for why streaming is not
# ported: the encoder has no KV cache, so re-running it on the full growing
# feature buffer every chunk measured too slow to hold real time.)
# ==========================================================================

_MOONSHINE_CHECKPOINT = "moonshine-ai/moonshine-streaming"

# frontend + encoder + adapter + decoder + decoder_kv only. ten-vad.onnx is
# a VAD graph this offline-only port never needs; cross_kv.onnx is skipped
# too -- decoder.onnx already derives k_cross/v_cross itself from `memory`
# on the first decode step (see _greedy_decode), so loading cross_kv would
# just cost RAM for output nobody reads.
_MOONSHINE_GRAPHS = ("frontend", "encoder", "adapter", "decoder", "decoder_kv")

# One encoder feature frame per 320 raw samples (20 ms @ 16 kHz) -- confirmed
# by direct experiment in the reference adapter's module docstring.
_FEATURE_HOP_SAMPLES = 320

# Model-card-derived cap on generated tokens, scaled to the audio seen so
# far. Bounds runaway generation without hardcoding a fixed token budget
# that would be wrong for short vs. long clips.
_TOKEN_LIMIT_FACTOR = 6.5 / SAMPLE_RATE
_MIN_MAX_LENGTH = 8


class MoonshineEngine:
    NAME = "moonshine"
    CHECKPOINT = _MOONSHINE_CHECKPOINT

    def __init__(self) -> None:
        self._sessions: dict = {}
        self._root: str | None = None
        self._tokenizer = None
        self._bos = 1
        self._eos = 2
        self._depth = self._nheads = self._head_dim = None
        self._zero_frontend_state: dict | None = None

    # --------------------------------------------------------------- setup

    def load(self, on_progress=None) -> None:
        from huggingface_hub import snapshot_download
        from tokenizers import Tokenizer

        snapshot_dir = snapshot_download(
            repo_id=self.CHECKPOINT,
            allow_patterns=["onnx/medium/*"],
            **_download_kwargs(on_progress),
        )
        self._root = os.path.join(snapshot_dir, "onnx", "medium")

        if on_progress:
            on_progress("load", 10)

        with open(os.path.join(self._root, "streaming_config.json")) as fh:
            config = json.load(fh)
        self._bos = config["bos_id"]
        self._eos = config["eos_id"]
        self._depth = config["depth"]
        self._nheads = config["nheads"]
        self._head_dim = config["head_dim"]

        shapes = config["frontend_state_shapes"]
        self._zero_frontend_state = {
            "sample_buffer": np.zeros(shapes["sample_buffer"], dtype=np.float32),
            "sample_len": np.zeros(shapes["sample_len"], dtype=np.int64),
            "conv1_buffer": np.zeros(shapes["conv1_buffer"], dtype=np.float32),
            "conv2_buffer": np.zeros(shapes["conv2_buffer"], dtype=np.float32),
            "frame_count": np.zeros(shapes["frame_count"], dtype=np.int64),
        }

        for i, name in enumerate(_MOONSHINE_GRAPHS):
            path = os.path.join(self._root, name + ".onnx")
            # CPUExecutionProvider only: CoreML supports only a fraction of
            # the nodes in each of these graphs and the encoder's input
            # shape changes every call, defeating compiled-plan reuse --
            # measured ~6-10x slower on this M1 (see the reference adapter).
            self._sessions[name] = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
            if on_progress:
                on_progress("load", 10 + 80 * (i + 1) // len(_MOONSHINE_GRAPHS))

        self._tokenizer = Tokenizer.from_file(os.path.join(self._root, "tokenizer.json"))
        if on_progress:
            on_progress("load", 100)

    def warmup(self) -> None:
        # Cheap: one transcribe() over silence pays ORT session/allocator
        # warm-up cost here instead of during the first real utterance.
        self.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))

    def unload(self) -> None:
        self._sessions = {}
        gc.collect()

    # ------------------------------------------------------------- helpers

    def _run_frontend(self, chunk: np.ndarray, state: dict):
        sess = self._sessions["frontend"]
        inputs = {"audio_chunk": chunk[None, :].astype(np.float32), **state}
        out = sess.run(None, inputs)
        outd = dict(zip((o.name for o in sess.get_outputs()), out))
        new_state = {
            "sample_buffer": outd["sample_buffer_out"],
            "sample_len": outd["sample_len_out"],
            "conv1_buffer": outd["conv1_buffer_out"],
            "conv2_buffer": outd["conv2_buffer_out"],
            "frame_count": outd["frame_count_out"],
        }
        return outd["features"], new_state

    def _greedy_decode(self, memory: np.ndarray, max_len: int) -> list[int]:
        token = np.array([[self._bos]], dtype=np.int64)
        k_self = np.zeros((self._depth, 1, self._nheads, 0, self._head_dim), dtype=np.float32)
        v_self = np.zeros((self._depth, 1, self._nheads, 0, self._head_dim), dtype=np.float32)

        logits, k_self, v_self, k_cross, v_cross = self._sessions["decoder"].run(
            None, {"token": token, "memory": memory, "k_self": k_self, "v_self": v_self}
        )
        ids = [int(np.argmax(logits[0, -1]))]

        while ids[-1] != self._eos and len(ids) < max_len:
            token = np.array([[ids[-1]]], dtype=np.int64)
            logits, k_self, v_self, k_cross, v_cross = self._sessions["decoder_kv"].run(
                None, {"token": token, "k_self": k_self, "v_self": v_self,
                       "out_k_cross": k_cross, "out_v_cross": v_cross}
            )
            ids.append(int(np.argmax(logits[0, -1])))
        return ids

    def _ids_to_text(self, ids: list[int]) -> str:
        content = [i for i in ids if i not in (self._bos, self._eos)]
        return self._tokenizer.decode(content).strip()

    # -------------------------------------------------------------- offline

    def transcribe(self, audio: np.ndarray) -> str:
        audio = np.asarray(audio, dtype=np.float32)
        # Below one frontend hop (20 ms) the conv graphs fail with an
        # opaque ONNX shape error; there is no speech to find anyway.
        if len(audio) < _FEATURE_HOP_SAMPLES:
            return ""
        feat, _ = self._run_frontend(audio, dict(self._zero_frontend_state))
        encoded = self._sessions["encoder"].run(None, {"features": feat})[0]
        memory = self._sessions["adapter"].run(
            None, {"encoded": encoded, "pos_offset": np.zeros((1,), dtype=np.int64)}
        )[0]
        n_samples = feat.shape[1] * _FEATURE_HOP_SAMPLES
        max_len = max(_MIN_MAX_LENGTH, int(n_samples * _TOKEN_LIMIT_FACTOR))
        ids = self._greedy_decode(memory, max_len)
        return self._ids_to_text(ids)


# ==========================================================================
# Nemotron (transformers AutoModelForRNNT, MPS with CPU fallback, true
# cache-aware streaming). torch/transformers are imported lazily inside
# load() -- see module docstring.
# ==========================================================================

_NEMOTRON_CHECKPOINT = "nvidia/nemotron-speech-streaming-en-0.6b"
# Fixed per design doc: 160 ms chunks only (num_lookahead_tokens=1). The
# reference adapter also supported 560 ms/lookahead=6 for benchmarking;
# this port drops that, there is exactly one streaming chunk size now.
_NEMOTRON_LOOKAHEAD = 1


class NemotronEngine:
    NAME = "nemotron"
    CHECKPOINT = _NEMOTRON_CHECKPOINT

    def __init__(self):
        self.device = None
        self.model = None
        self.processor = None
        self._offline_lookahead = None
        self._reset_stream_state()

    # ------------------------------------------------------------ lifecycle

    def load(self, on_progress=None) -> None:
        # torch/transformers are the multi-GB "streaming" extra (design
        # doc): a Moonshine-only install never has them. Import lazily as
        # module globals here, once, so every other method below keeps
        # using bare `torch.*` / `TextIteratorStreamer` exactly like the
        # ported adapter -- they only ever run after this import succeeded.
        global torch, TextIteratorStreamer
        try:
            import torch
            from transformers import AutoModelForRNNT, AutoProcessor, TextIteratorStreamer
        except ImportError as exc:
            raise MissingStreamingDeps(
                "streaming mode needs torch/torchaudio/transformers "
                "(requirements-streaming.txt is not installed)"
            ) from exc

        def emit(stage, pct):
            if on_progress:
                on_progress(stage, pct)

        # MPS + this model's background-thread streaming genuinely crashed
        # the process (Metal "commit an already committed command buffer")
        # until the thread-discipline fix in _mel_generator/
        # _start_generate_thread (torch.mps.* is now only ever called by the
        # one thread doing the compute). Verified stable across repeated
        # runs after that fix -- default stays MPS. NEMOTRON_FORCE_CPU=1 is
        # a manual escape hatch if this resurfaces elsewhere.
        force_cpu = os.environ.get("NEMOTRON_FORCE_CPU") == "1"
        self.device = "cpu" if force_cpu else ("mps" if torch.backends.mps.is_available() else "cpu")

        from huggingface_hub import snapshot_download
        emit("download", 0)
        snapshot_download(repo_id=self.CHECKPOINT, **_download_kwargs(on_progress))
        emit("download", 100)

        emit("load", 20)
        # No dtype override: load whatever the checkpoint declares
        # (float32, per config.json) -- never hardcode precision.
        self.processor = AutoProcessor.from_pretrained(self.CHECKPOINT)
        emit("load", 60)
        self.model = AutoModelForRNNT.from_pretrained(self.CHECKPOINT)
        self.model.to(self.device)
        self.model.eval()
        emit("load", 100)

        # Offline transcription always uses the widest trained context (best
        # accuracy), fixed at load time so a prior streaming session's
        # lookahead override can never leak into the offline path.
        self._offline_lookahead = self.processor.supported_num_lookahead_tokens[0]

    def warmup(self) -> None:
        # Cheap: one transcribe() over silence exercises PyTorch/MPS graph
        # tracing and kernel selection before the first real utterance.
        self.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        self._reset_stream_state()

    def unload(self) -> None:
        # abort() first: dropping the queue/thread references while a
        # generate() worker still blocks on q.get() would leak the whole
        # model through the worker's stack.
        self.abort()
        self.model = None
        self.processor = None
        if self.device == "mps":
            torch.mps.empty_cache()
        gc.collect()

    def abort(self) -> None:
        """Tear down an in-flight utterance without decoding a final.

        Called on unload and on any failed stream/finalize op, so the next
        utterance never inherits this one's worker, buffer, or transcript.
        """
        if self._thread is not None:
            self._mel_queue.put(None)  # ends the generator -> generate() stops
            self._thread.join(timeout=10)
            if self._thread.is_alive():
                # Wedged worker: it may still own the MPS command buffer,
                # so never touch torch.mps.* from this thread (see
                # _mel_generator). The app's recovery is a sidecar restart.
                self._reset_stream_state()
                return
        self._sync()
        self._reset_stream_state()

    def _sync(self) -> None:
        if self.device == "mps":
            torch.mps.synchronize()

    # -------------------------------------------------------------- offline

    def transcribe(self, audio: np.ndarray) -> str:
        inputs = self.processor(audio, sampling_rate=SAMPLE_RATE, return_tensors="pt")
        inputs["num_lookahead_tokens"] = self._offline_lookahead
        inputs = inputs.to(self.device, dtype=self.model.dtype)
        # Explicit, generous bound (encoder frames * max_symbols_per_step,
        # plus slack) so generate() never hits the library's silent 550-
        # token default and truncates a longer clip.
        duration_s = len(audio) / SAMPLE_RATE
        max_new_tokens = int(duration_s * 1000 / 80 * self.model.config.max_symbols_per_step) + 64
        with torch.inference_mode():
            out = self.model.generate(**inputs, max_new_tokens=max_new_tokens, return_dict_in_generate=True)
        text = self.processor.decode(out.sequences[0], skip_special_tokens=True)
        self._sync()
        return text

    # ------------------------------------------------------------- streaming

    def _reset_stream_state(self) -> None:
        self._buf = np.zeros(0, dtype=np.float32)
        self._consumed_core = 0     # sample offset already turned into mel chunks
        self._first_done = False    # first chunk (center=True) vs subsequent (center=False)
        self._right = None          # num_lookahead_tokens for this utterance
        self._mel_queue = None
        self._streamer = None
        self._thread = None
        self._thread_err = None
        self._transcript = ""
        # "" (not None): the first drain that yields no text must not be
        # reported as a grown partial.
        self._last_returned = ""
        self._active = False
        # Set by the background thread the instant it is blocked on q.get()
        # with nothing left to process -- see the MPS note below.
        self._idle_event = None

    def _mel_generator(self, q, idle_event):
        """Consumed by model.generate() on the background thread.

        MPS is not safe to touch from two threads at all (verified the hard
        way: this crashed the process with Metal "commit an already
        committed command buffer" / "uncommitted encoder" assertions --
        and that held even after gating the *main* thread's
        torch.mps.synchronize() behind an idle handshake, so it is not just
        a submit/sync timing race: PyTorch's MPS command buffer appears
        thread-affine to whichever thread encoded into it). The fix is
        stricter than "don't race": torch.mps.synchronize() is only ever
        called from *this* thread, right here, and the main thread (see
        stream()/finalize()) never touches torch.mps.* while this thread
        could still be alive. idle_event is the handshake that tells the
        main thread when that is true: set only once this thread's own
        sync has completed and it is blocked in pure Python on queue.get().
        """
        while True:
            self._sync()  # same-thread sync of the forward pass(es) just run
            idle_event.set()
            item = q.get()
            idle_event.clear()
            if item is None:
                return
            yield item.to(device=self.device, dtype=self.model.dtype)

    def _start_generate_thread(self, q, streamer, right, idle_event):
        def target():
            try:
                with torch.inference_mode():
                    self.model.generate(
                        input_features=self._mel_generator(q, idle_event),
                        num_lookahead_tokens=right,
                        streamer=streamer,
                        # Real audio length is unknown up front in streaming
                        # mode; this is a safety ceiling only -- actual
                        # stopping is the encoder-exhaustion criteria once
                        # finalize() closes the generator.
                        max_new_tokens=100_000,
                    )
            except Exception as exc:  # surfaced to the caller in finalize()/stream()
                self._thread_err = exc
                streamer.text_queue.put(streamer.stop_signal)
            finally:
                # generate() can still do a bit of MPS work (flushing the
                # last decode step(s)) after the generator's own last sync.
                # Sync here, on this same thread, one last time before it
                # ever terminates, so finalize()'s post-join sync on the
                # main thread is a true no-op.
                self._sync()
                idle_event.set()  # unblock any waiter even if generate() raised

        t = threading.Thread(target=target, daemon=True)
        t.start()
        return t

    def _emit_ready_mel_chunks(self) -> None:
        """Slice buffered raw audio into model-native chunks and enqueue them.

        Chunk boundaries here are the model's own (num_samples_first/
        per_audio_chunk), not the caller's 160 ms -- the two rarely coincide
        exactly because framing needs a little extra trailing context
        (win_length) beyond the pure hop_length * n_frames span. Buffering
        internally like this fully decouples external delivery granularity
        from the model's real streaming step size.
        """
        proc = self.processor
        hop = proc.feature_extractor.hop_length
        first_frames = proc.num_mel_frames_first_audio_chunk
        per_frames = proc.num_mel_frames_per_audio_chunk
        first_need = proc.num_samples_first_audio_chunk
        per_need = proc.num_samples_per_audio_chunk
        put_any = False

        while True:
            avail = len(self._buf) - self._consumed_core
            if not self._first_done:
                if avail < first_need:
                    break
                piece = self._buf[self._consumed_core:self._consumed_core + first_need]
                feat = proc(piece, sampling_rate=SAMPLE_RATE, is_streaming=True,
                            is_first_audio_chunk=True, return_tensors="pt").input_features
                # center=True STFT can pad in one extra (invalid) trailing
                # frame; truncate to the exact count the model requires
                # (matches NVIDIA's own streaming example).
                feat = feat[:, :first_frames, :]
                self._consumed_core += first_frames * hop
                self._first_done = True
            else:
                if avail < per_need:
                    break
                piece = self._buf[self._consumed_core:self._consumed_core + per_need]
                feat = proc(piece, sampling_rate=SAMPLE_RATE, is_streaming=True,
                            is_first_audio_chunk=False, return_tensors="pt").input_features
                self._consumed_core += per_frames * hop

            if self._mel_queue is None:
                self._mel_queue = queue.Queue()
                self._idle_event = threading.Event()
                self._streamer = TextIteratorStreamer(self.processor.tokenizer, skip_special_tokens=True)
            self._mel_queue.put(feat)
            put_any = True
            if self._thread is None:
                self._thread = self._start_generate_thread(
                    self._mel_queue, self._streamer, self._right, self._idle_event
                )

        if put_any:
            # Block until the background thread has consumed everything
            # just queued and is back to idling on q.get() -- only then is
            # it safe for the main thread to touch torch.mps.* (see
            # _mel_generator's docstring).
            if not self._idle_event.wait(timeout=30):
                raise RuntimeError("nemotron: streaming worker did not keep up (timed out)")

    def _drain_text(self) -> None:
        if self._streamer is None:
            return
        while True:
            try:
                piece = self._streamer.text_queue.get_nowait()
            except queue.Empty:
                return
            if piece is None:
                continue
            self._transcript += piece

    def stream(self, chunk) -> str | None:
        if not self._active:
            self._reset_stream_state()
            self._active = True

        chunk = np.asarray(chunk, dtype=np.float32)
        if self._right is None:
            # Fixed at 160 ms / lookahead=1 (design doc); must be set once
            # before the first mel chunk is built from it.
            self._right = _NEMOTRON_LOOKAHEAD
            self.processor.set_num_lookahead_tokens(self._right)

        self._buf = np.concatenate([self._buf, chunk])
        # _emit_ready_mel_chunks() blocks (via idle_event) until the
        # background thread has synced its own MPS work and gone idle, so
        # by this point GPU compute for everything fed so far is genuinely
        # finished -- the main thread itself never calls torch.mps.* while
        # the worker thread could still be alive (see _mel_generator).
        self._emit_ready_mel_chunks()
        self._drain_text()

        if self._thread_err is not None:
            err = self._thread_err
            self._reset_stream_state()
            raise RuntimeError("nemotron: streaming generate() failed") from err

        if self._transcript != self._last_returned:
            self._last_returned = self._transcript
            return self._transcript
        return None

    def finalize(self) -> str:
        if not self._active:
            return ""

        proc = self.processor
        avail = len(self._buf) - self._consumed_core
        if avail > 0:
            is_first = not self._first_done
            need = proc.num_samples_first_audio_chunk if is_first else proc.num_samples_per_audio_chunk
            frames = proc.num_mel_frames_first_audio_chunk if is_first else proc.num_mel_frames_per_audio_chunk
            piece = self._buf[self._consumed_core:]
            piece = np.pad(piece, (0, need - len(piece)))
            feat = proc(piece, sampling_rate=SAMPLE_RATE, is_streaming=True,
                        is_first_audio_chunk=is_first, return_tensors="pt").input_features
            feat = feat[:, :frames, :]
            self._first_done = True
            if self._mel_queue is None:
                self._mel_queue = queue.Queue()
                self._idle_event = threading.Event()
                self._streamer = TextIteratorStreamer(self.processor.tokenizer, skip_special_tokens=True)
            self._mel_queue.put(feat)
            if self._thread is None:
                self._thread = self._start_generate_thread(
                    self._mel_queue, self._streamer, self._right, self._idle_event
                )
            # No idle_event wait needed here: the next thing we do is put
            # the end-of-stream sentinel and join() the thread to
            # completion, so the main thread never touches torch.mps.*
            # until the thread is fully done.

        err = None
        wedged = False
        if self._thread is not None:
            self._mel_queue.put(None)  # ends the generator -> generate() stops
            self._thread.join(timeout=60)
            wedged = self._thread.is_alive()
            if wedged:
                err = RuntimeError("nemotron: streaming generate() thread did not finish in time")
            self._drain_text()
            if self._thread_err is not None:
                err = self._thread_err

        final_text = self._transcript
        if not wedged:
            # A wedged worker may still own the MPS command buffer; never
            # sync from this thread then (see _mel_generator).
            self._sync()
        # Full reset: next stream() call starts a brand new generate()
        # thread with brand new encoder_past_key_values/padding_cache/
        # decoder_cache (those live inside that one generate() call and are
        # never stored on self), so nothing from this clip can leak into
        # the next.
        self._reset_stream_state()
        if err is not None:
            raise RuntimeError("nemotron: streaming generate() failed") from err
        return final_text

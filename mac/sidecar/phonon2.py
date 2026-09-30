"""Phonon-2 on MLX: Standard mode's Best level.

Phonon-2 (`FermionResearch/Phonon-2`) is NVIDIA's Parakeet TDT 0.6B v3 with
its 264 encoder linears retrained to five values per row: 0, +-lo and +-hi.
It runs on mlx-audio's Parakeet graph, and each of those linears runs as two
native 2-bit MLX matmuls.

The first load downloads the 164 MB archive, decodes it one layer at a time,
and saves the packed weights (334 MB) next to the config. Every later load
reads that file: about 0.2 s, against about 4.5 s for the first one on an M1.
Fermion's own loader decodes the whole file at once and peaks near 2.7 GB.
This one peaks near 750 MB and gives the same parameters, bit for bit.

This module imports mlx at module level. engines.Phonon2Engine imports it
inside load(), so the sidecar still starts when the MLX runtime is absent.

Parts of this file come from fermion-research 0.2.3
(https://github.com/fermionresearch/phonon), Copyright 2026 Fermion Research,
under the Apache License 2.0 (see LICENSE-fermion.txt): the container record
layout and _intn(), the HF-to-MLX name map, PackedFiveValueLinear, the fp32
log-mel patch and the fast TDT loop. Changes: the loader decodes one record
at a time on the GPU and caches the packed planes, and only the code this
app calls is kept.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx.utils import tree_flatten
from mlx_audio.stt.models.parakeet import Model
from mlx_audio.stt.models.parakeet import audio as _audio
from mlx_audio.stt.models.parakeet import parakeet as _pk
from mlx_audio.stt.models.parakeet import tokenizer as _tok

REPO = "FermionResearch/Phonon-2"
# A pinned commit: the files cannot change under the app, and the packed
# cache below belongs to exactly this revision.
REVISION = "e357655f6325aa70d4800d125273a5ed3a703b9c"
ARCHIVE = "phonon-2.bps.tar.zst"
ARCHIVE_SHA256 = "98125795b6dda72f5c6eee9ba33d19815df65dcb18b50a357bf9f73c9935309e"

MODELS = Path.home() / "Library/Application Support/OpenVox/models/phonon-2"
# The folder name also carries the layout version of the packed file, so a
# change to that layout builds a new cache instead of misreading the old one.
MODEL_DIR = MODELS / f"{REVISION[:12]}-packed-v1"

CONTAINER_FORMAT = "fermion-five-value-parakeet-v1"
FIVE_VALUE_MODULES = 264
GROUP = 128

# Audio longer than this is decoded in windows of this length, with
# mlx-audio's own overlap merge. Measured on an M1 over a 5 min dictation:
# 8.3% WER and a 1.1 GB MLX peak, against 12.0% and 2.5 GB in one pass.
# Shorter audio is one pass.
CHUNK_SECONDS = 30.0


# ==========================================================================
# Load
# ==========================================================================

def load(on_progress=None, download_kwargs: dict | None = None) -> nn.Module:
    """-> a ParakeetTDT ready to transcribe. The first call builds the cache."""
    _install_fp32_frontend()
    # MLX keeps freed buffers for reuse, and with variable-length audio no
    # buffer is ever reused: over 68 clips the process grew to 4.4 GB.
    # With no cache it holds 530 MB at the same speed.
    mx.set_cache_limit(0)
    for attempt in range(2):
        if not (MODEL_DIR / "model.safetensors").exists():
            _build(on_progress, download_kwargs or {})
        model = Model.from_config(json.loads((MODEL_DIR / "config.json").read_text()))
        try:
            _load_packed(model, MODEL_DIR / "model.safetensors")
            break
        except Exception:
            # A damaged cache must not break Best for good: build it again, once.
            shutil.rmtree(MODEL_DIR, ignore_errors=True)
            if attempt:
                raise
    model.eval()
    _install_fast_tdt(model)
    if on_progress:
        on_progress("load", 100)
    return model


def transcribe(model: nn.Module, audio: np.ndarray) -> str:
    x = mx.array(np.asarray(audio, dtype=np.float32))
    return model.generate(x, dtype=mx.bfloat16, chunk_duration=CHUNK_SECONDS).text.strip()


def _build(on_progress, download_kwargs: dict) -> None:
    """Download the archive, pack its weights, and save them to MODEL_DIR."""
    from huggingface_hub import hf_hub_download

    MODELS.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(dir=MODELS))
    try:
        archive = Path(hf_hub_download(REPO, ARCHIVE, revision=REVISION, local_dir=tmp,
                                       **download_kwargs))
        digest = hashlib.sha256()
        with open(archive, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                digest.update(block)
        if digest.hexdigest() != ARCHIVE_SHA256:
            raise RuntimeError(f"{ARCHIVE}: sha256 {digest.hexdigest()} is not the pinned one")
        _unpack(archive, tmp)
        archive.unlink()
        shutil.rmtree(tmp / ".cache", ignore_errors=True)  # hf_hub_download's local_dir metadata

        model = Model.from_config(json.loads((tmp / "config.json").read_text()))
        _pack_container(model, tmp / "model.fermion", on_progress)
        mx.save_safetensors(str(tmp / "model.safetensors"), dict(tree_flatten(model.parameters())))
        del model
        (tmp / "model.fermion").unlink()

        # Remove older revisions and anything a crash left behind, then
        # move the finished folder in with one rename.
        for old in MODELS.iterdir():
            if old != tmp:
                shutil.rmtree(old, ignore_errors=True)
        os.replace(tmp, MODEL_DIR)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unpack(archive: Path, dest: Path) -> None:
    """Extract the two files the build reads. Member names never become paths."""
    import zstandard

    want = {"model.fermion", "config.json"}
    with open(archive, "rb") as fh, zstandard.ZstdDecompressor().stream_reader(fh) as z, \
            tarfile.open(fileobj=z, mode="r|") as tar:
        for member in tar:
            if member.isfile() and member.name in want:
                with tar.extractfile(member) as src, open(dest / member.name, "wb") as out:
                    shutil.copyfileobj(src, out, 1 << 20)
                want.discard(member.name)
    if want:
        raise RuntimeError(f"{ARCHIVE} does not hold {sorted(want)}")


def _load_packed(model: nn.Module, path: Path) -> None:
    """Load the planes that _build() saved. No decode, no pack."""
    weights = mx.load(str(path))
    packed = []
    for key, q in weights.items():
        if key.endswith(".base_q"):
            name = key.removesuffix(".base_q")
            parent, leaf = _resolve(model, name)
            m = PackedFiveValueLinear(q.shape[1] * 16, q.shape[0], bias=f"{name}.bias" in weights)
            setattr(parent, leaf, m)
            packed.append(m)
    if len(packed) != FIVE_VALUE_MODULES:
        raise RuntimeError(f"{path.name}: {len(packed)} packed modules, expected {FIVE_VALUE_MODULES}")
    model.load_weights(list(weights.items()), strict=True)  # every key and shape, both ways
    mx.eval(model.parameters())
    for m in packed:
        m.materialize_runtime_metadata()


def _pack_container(model: nn.Module, path: Path, on_progress) -> None:
    """Fill `model` from a fermion-five-value-parakeet-v1 container.

    The container is an 8-byte header length, a JSON header with an index,
    then one record per tensor in index order. Pass 1 loads the small dense
    tensors. Pass 2 packs each five-value record and frees it before it
    reads the next, so the build never holds more than one layer's tables.
    """
    with open(path, "rb") as fh:
        n = int.from_bytes(fh.read(8), "little")
        header = json.loads(fh.read(n))
        if header["format"] != CONTAINER_FORMAT:
            raise RuntimeError(f"unknown container format {header['format']!r}")
        index = header["index"]
        offsets = np.cumsum([8 + n] + [e["b"] for e in index]).tolist()
        if offsets[-1] != fh.seek(0, 2):
            raise RuntimeError("container size does not match its index")

        def blob(j: int) -> bytes:
            fh.seek(offsets[j])
            return fh.read(index[j]["b"])

        # Pass 1. The biases of the quantised linears are in here, and the
        # substitution copies them, so this pass must come first.
        dense, five_value = {}, []
        for j, e in enumerate(index):
            kind, shape = e["k"], tuple(e["shape"])
            if kind == "five_value":
                five_value.append(j)
            elif kind.startswith("int"):
                dense[e["n"]] = _intn(blob(j), shape, int(kind[3:]))
            elif kind == "fp16":
                dense[e["n"]] = np.frombuffer(blob(j), np.float16).reshape(shape)
            else:
                raise RuntimeError(f"unknown record kind {kind!r}")
        if len(five_value) != FIVE_VALUE_MODULES:
            raise RuntimeError(f"{len(five_value)} five-value records, expected {FIVE_VALUE_MODULES}")
        weights = [(k, mx.array(v).astype(mx.bfloat16)) for k, v in _hf_to_mlx(dense).items()]
        del dense
        fv_names = {_five_value_hf_to_mlx(index[j]["n"]) + ".weight" for j in five_value}
        want = {k for k, _ in tree_flatten(model.parameters())} - fv_names
        got = {k for k, _ in weights}
        if want != got:
            raise RuntimeError(f"weights missing {sorted(want - got)[:5]}, unexpected {sorted(got - want)[:5]}")
        model.load_weights(weights, strict=False)
        del weights

        # Pass 2.
        for done, j in enumerate(five_value):
            _substitute(model, index[j]["n"], blob(j), *index[j]["shape"])
            if on_progress:
                on_progress("load", 10 + 80 * (done + 1) // len(five_value))
    mx.eval(model.parameters())


# ==========================================================================
# Five-value records -> two 2-bit planes
# ==========================================================================

# Byte b holds five base-3 digits (b < 243), one weight code each: 0, 1 or 2
# for -1, 0 and +1. 256 rows so that any byte decodes, as in Fermion's reader.
_TRITS = mx.array(((np.arange(256)[:, None] // 3 ** np.arange(5)) % 3).astype(np.uint32))
_SHIFTS = mx.arange(0, 32, 2).astype(mx.uint32)


def _pack_2bit(q: mx.array) -> mx.array:
    """(O, I) codes in {0..3} -> (O, I/16) uint32, element j of each run of 16
    in bits 2j..2j+1: the MLX affine layout."""
    o, i = q.shape
    return (q.reshape(o, i // 16, 16) << _SHIFTS).sum(axis=-1)


def _packed_linear(blob: bytes, o: int, i: int, bias) -> PackedFiveValueLinear:
    """One five-value record -> PackedFiveValueLinear, decoded on the GPU.

    Record layout: the codes (five per byte, rows padded to whole bytes), one
    residual bit per nonzero weight in row-major order, then per-row fp16 lo
    and hi. A weight is 0, +-lo, or +-hi where its residual bit is set.
    Plane A holds the code, which is sign + 1. Plane B holds the code where
    the residual bit is set and 1 elsewhere, which is 1 + sign * is_hi.
    """
    rb = (i + 4) // 5
    codes = _TRITS[mx.array(np.frombuffer(blob, np.uint8, o * rb))].reshape(o, rb * 5)[:, :i]
    nonzero = codes != 1
    off = o * rb
    # The byte length gives the bit count, so this needs no GPU sync.
    rbytes = len(blob) - off - 4 * o
    nnz = nonzero.sum()  # checked after the eval below
    rank = mx.maximum(mx.cumsum(nonzero.flatten().astype(mx.int32)) - 1, 0)
    bits = mx.array(np.frombuffer(blob, np.uint8, rbytes, off)).astype(mx.uint32)
    is_hi = nonzero & ((bits[rank // 8] >> (rank % 8).astype(mx.uint32)) & 1).astype(mx.bool_).reshape(o, i)
    off += rbytes
    lo = np.frombuffer(blob, np.float16, o, off)
    hi = np.frombuffer(blob, np.float16, o, off + 2 * o)
    if np.any(hi.astype(np.float32) < lo.astype(np.float32)):
        raise RuntimeError("a row has hi < lo")

    m = PackedFiveValueLinear(i, o, bias=bias is not None)
    m.base_q = _pack_2bit(codes)
    m.residual_q = _pack_2bit(mx.where(is_hi, codes, 1))
    m.row_lo, m.row_hi = mx.array(lo), mx.array(hi)
    if bias is not None:
        m.bias = bias.astype(mx.float32)
    # Evaluate now, so this record's temporaries are gone before the next one.
    mx.eval(m.base_q, m.residual_q, m.row_lo, m.row_hi, nnz)
    if (nnz.item() + 7) // 8 != rbytes:
        raise RuntimeError(f"record holds {rbytes} residual bytes for {nnz.item()} nonzero weights")
    m.materialize_runtime_metadata()
    return m


def _substitute(model: nn.Module, hf_name: str, blob: bytes, o: int, i: int) -> None:
    parent, leaf = _resolve(model, _five_value_hf_to_mlx(hf_name))
    old = getattr(parent, leaf)
    want = (o, i) if isinstance(old, nn.Linear) else (o, 1, i) if isinstance(old, nn.Conv1d) else None
    if want is None or tuple(old.weight.shape) != want or i % GROUP:
        raise RuntimeError(f"{hf_name}: cannot replace {type(old).__name__} "
                           f"{tuple(old.weight.shape)} with ({o}, {i})")
    setattr(parent, leaf, _packed_linear(blob, o, i, old.bias if "bias" in old else None))


def _intn(blob: bytes, shape, bits: int) -> np.ndarray:
    """An int8 or int6 table with one fp16 scale per row -> float32. From Fermion."""
    o = shape[0]
    total = int(np.prod(shape))
    body, scales = blob[:-2 * o], np.frombuffer(blob[-2 * o:], dtype=np.float16)
    if bits == 8:
        q = np.frombuffer(body, dtype=np.int8).astype(np.int32)[:total]
    elif bits == 6:
        b = np.frombuffer(body, dtype=np.uint8).reshape(-1, 3).astype(np.uint32)
        packed = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        u = np.stack([(packed >> s) & 0x3F for s in (0, 6, 12, 18)], axis=1).ravel()
        q = u[:total].astype(np.int32) - 32
    else:
        raise RuntimeError(f"unknown table width int{bits}")
    w = q.reshape(o, total // o).astype(np.float32) * scales.astype(np.float32)[:, None]
    return w.reshape(shape)


class PackedFiveValueLinear(nn.Module):
    """A five-value linear as two native 2-bit affine QMMs. From Fermion.

    With per-row lo and d = hi - lo, plane A gives lo * q_a - lo = sign * lo
    and plane B gives d * q_b - d = sign * is_hi * d. Their sum is 0, +-lo or
    +-hi, exact in fp32. It also stands in for mlx-audio's kernel-1 Conv1d,
    which is channels-last and so a linear over the last axis.
    """

    def __init__(self, in_features: int, out_features: int, *, bias: bool = False):
        super().__init__()
        if in_features % GROUP:
            raise ValueError(f"in_features={in_features} is not divisible by {GROUP}")
        self.in_features = in_features
        self.out_features = out_features
        self.base_q = mx.zeros((out_features, in_features // 16), dtype=mx.uint32)
        self.residual_q = mx.zeros((out_features, in_features // 16), dtype=mx.uint32)
        self.row_lo = mx.zeros((out_features,), dtype=mx.float16)
        self.row_hi = mx.zeros((out_features,), dtype=mx.float16)
        if bias:
            self.bias = mx.zeros((out_features,), dtype=mx.float32)

    def materialize_runtime_metadata(self) -> None:
        """Broadcast per-row lo and d to the per-group scales and biases QMM
        takes. They must be contiguous: a stride-0 view is not valid input."""
        shape = (self.out_features, self.in_features // GROUP)
        lo = self.row_lo.astype(mx.float32)
        d = self.row_hi.astype(mx.float32) - lo  # exact: two fp16 values in fp32
        self._base_scales = mx.contiguous(mx.broadcast_to(lo[:, None], shape))
        self._base_biases = mx.contiguous(-self._base_scales)
        self._resid_scales = mx.contiguous(mx.broadcast_to(d[:, None], shape))
        self._resid_biases = mx.contiguous(-self._resid_scales)
        mx.eval(self._base_scales, self._base_biases, self._resid_scales, self._resid_biases)

    def __call__(self, x: mx.array) -> mx.array:
        in_dtype = x.dtype
        x = x.astype(mx.float32)
        y = mx.quantized_matmul(x, self.base_q, self._base_scales, self._base_biases,
                                transpose=True, group_size=GROUP, bits=2, mode="affine")
        y = y + mx.quantized_matmul(x, self.residual_q, self._resid_scales, self._resid_biases,
                                    transpose=True, group_size=GROUP, bits=2, mode="affine")
        if "bias" in self:
            y = y + self.bias
        return y.astype(in_dtype)


# ==========================================================================
# Names: HF ParakeetForTDT -> mlx-audio ParakeetTDT. From Fermion.
# ==========================================================================

_SUB = {"0", "2", "3", "5", "6"}
_ATT = {"q_proj": "linear_q", "k_proj": "linear_k", "v_proj": "linear_v",
        "o_proj": "linear_out", "relative_k_proj": "linear_pos",
        "bias_u": "pos_bias_u", "bias_v": "pos_bias_v"}
_FF_CONV = {"feed_forward1.linear1", "feed_forward1.linear2",
            "feed_forward2.linear1", "feed_forward2.linear2",
            "conv.pointwise_conv1", "conv.pointwise_conv2"}


def _five_value_hf_to_mlx(hf_name: str) -> str:
    """The module path of one of the 264 quantised encoder linears."""
    m = re.fullmatch(r"encoder\.layers\.(\d+)\.(.+)", hf_name)
    tail = m and m.group(2)
    if tail and tail.startswith("self_attn.") and tail[10:] in _ATT:
        tail = "self_attn." + _ATT[tail[10:]]
    elif tail not in _FF_CONV:
        raise KeyError(hf_name)
    return f"encoder.layers.{m.group(1)}.{tail}"


def _hf_to_mlx(hf: dict) -> dict:
    """Dense tensors, HF names -> mlx-audio names. MLX convs are channels-last:
    Conv2d [O,I,H,W] -> [O,H,W,I] and Conv1d [O,I,K] -> [O,K,I]. The LSTM
    weights are renamed and its two biases summed. num_batches_tracked is
    dropped."""
    out, used = {}, set()

    def put(k_new, v, src):
        assert k_new not in out, k_new
        out[k_new] = v
        used.update(src if isinstance(src, (list, tuple)) else [src])

    for k, v in hf.items():
        if k.endswith("num_batches_tracked"):
            used.add(k)
            continue
        m = re.fullmatch(r"encoder\.subsampling\.layers\.(\d+)\.(weight|bias)", k)
        if m:
            assert m.group(1) in _SUB, k
            put(f"encoder.pre_encode.conv.{m.group(1)}.{m.group(2)}",
                v.transpose(0, 2, 3, 1) if m.group(2) == "weight" else v, k)
            continue
        m = re.fullmatch(r"encoder\.subsampling\.linear\.(weight|bias)", k)
        if m:
            put(f"encoder.pre_encode.out.{m.group(1)}", v, k)
            continue
        m = re.fullmatch(r"encoder\.layers\.(\d+)\.(.+)", k)
        if m:
            layer, rest = m.groups()
            p = f"encoder.layers.{layer}."
            a = re.fullmatch(r"self_attn\.(\w+?)(\.weight)?", rest)
            if a and a.group(1) in _ATT:
                put(p + "self_attn." + _ATT[a.group(1)] + (a.group(2) or ""), v, k)
                continue
            c = re.fullmatch(r"conv\.(pointwise_conv[12])\.weight", rest)
            if c:
                w = v if v.ndim == 3 else v[:, :, None]
                put(p + f"conv.{c.group(1)}.weight", w.transpose(0, 2, 1), k)
                continue
            if rest == "conv.depthwise_conv.weight":
                put(p + "conv.depthwise_conv.weight", v.transpose(0, 2, 1), k)
                continue
            n = re.fullmatch(r"conv\.norm\.(weight|bias|running_mean|running_var)", rest)
            if n:
                put(p + f"conv.batch_norm.{n.group(1)}", v, k)
                continue
            if re.fullmatch(r"(norm_(feed_forward[12]|self_att|conv|out)|feed_forward[12]\.linear[12])\.(weight|bias)", rest):
                put(p + rest, v, k)
                continue
            raise KeyError(k)
        m = re.fullmatch(r"encoder_projector\.(weight|bias)", k)
        if m:
            put(f"joint.enc.{m.group(1)}", v, k)
            continue
        m = re.fullmatch(r"decoder\.decoder_projector\.(weight|bias)", k)
        if m:
            put(f"joint.pred.{m.group(1)}", v, k)
            continue
        m = re.fullmatch(r"joint\.head\.(weight|bias)", k)
        if m:
            put(f"joint.joint_net.2.{m.group(1)}", v, k)
            continue
        if k == "decoder.embedding.weight":
            put("decoder.prediction.embed.weight", v, k)
            continue
        m = re.fullmatch(r"decoder\.lstm\.weight_(ih|hh)_l(\d+)", k)
        if m:
            put(f"decoder.prediction.dec_rnn.lstm.{m.group(2)}.{'Wx' if m.group(1) == 'ih' else 'Wh'}", v, k)
            continue
        m = re.fullmatch(r"decoder\.lstm\.bias_ih_l(\d+)", k)
        if m:
            kh = f"decoder.lstm.bias_hh_l{m.group(1)}"
            b = (v.astype(np.float32) + hf[kh].astype(np.float32)).astype(v.dtype)
            put(f"decoder.prediction.dec_rnn.lstm.{m.group(1)}.bias", b, [k, kh])
            continue
        if re.fullmatch(r"decoder\.lstm\.bias_hh_l\d+", k):
            continue
        raise KeyError(f"unmapped HF key: {k}")
    missing = set(hf) - used
    assert not missing, sorted(missing)[:10]
    return out


def _resolve(root: nn.Module, dotted: str):
    parent = root
    parts = dotted.split(".")
    for p in parts[:-1]:
        parent = parent[int(p)] if p.isdigit() else getattr(parent, p)
    return parent, parts[-1]


# ==========================================================================
# Runtime patches to mlx-audio. From Fermion.
# ==========================================================================

def _install_fp32_frontend() -> None:
    """Compute the log-mel front end in fp32, then cast to the audio dtype.

    mlx-audio computes it in the audio dtype, and its per-feature
    normalisation sums over time. In bf16, 3 of the 68 benchmark clips and a
    60 s clip transcribe differently, and one comes back empty.
    """
    if getattr(_pk, "_openvox_fp32_frontend", False):
        return
    original = _audio.log_mel_spectrogram

    def log_mel_spectrogram_fp32(x, args):
        return original(x.astype(mx.float32), args).astype(x.dtype)

    _pk.log_mel_spectrogram = log_mel_spectrogram_fp32
    _pk._openvox_fp32_frontend = True


# One host sync per 16 decode steps instead of one per step: 270 ms against
# 400 ms median to final text over the 68 benchmark clips, same transcripts.
_TDT_BLOCK = 16


def _install_fast_tdt(model: nn.Module) -> None:
    """Replace ParakeetTDT.decode with a greedy TDT loop that stays on the GPU.

    The same compiled `_tdt_step` graph runs _TDT_BLOCK steps at a time, with
    the control flow (blank, duration, max_symbols) as mx.where. Steps past
    the end of the audio are computed and then masked out.
    """
    model._fast_step = _make_fast_step(model)
    model.decode = _decode_fast.__get__(model, type(model))


def _make_fast_step(self):
    blank = self.blank_id
    max_symbols = self.max_symbols
    durations = mx.array(self.durations, dtype=mx.int32)
    tdt_step = self._tdt_step

    def fast_step(feature, last, h, c, t, nsym, max_len):
        valid = t < max_len
        pred, dec, h2, c2 = tdt_step(feature, last.reshape(1, 1), h, c)
        dur = mx.take(durations, dec)
        emit = mx.logical_and(valid, pred != blank)
        tok_out = mx.where(emit, pred, -1)
        last = mx.where(emit, pred, last)
        h = mx.where(emit, h2, h)
        c = mx.where(emit, c2, c)
        nsym = nsym + 1
        t_adv = t + dur
        if max_symbols is not None:
            hit = mx.logical_and(dur == 0, nsym >= max_symbols)
            t_adv = mx.where(hit, t_adv + 1, t_adv)
            nsym = mx.where(mx.logical_or(dur != 0, hit), 0, nsym)
        else:
            nsym = mx.where(dur != 0, 0, nsym)
        t_new = mx.where(valid, t_adv, t)
        idx_next = mx.minimum(t_new, max_len - 1)
        return tok_out, t, dur, t_new, last, h, c, nsym, idx_next

    return mx.compile(fast_step)


def _decode_fast(self, mel: mx.array):
    batch_size = mel.shape[0]
    if mel.ndim == 2:
        batch_size = 1
        mel = mx.expand_dims(mel, 0)
    batch_features, lengths = self.encoder(mel)
    mx.eval(batch_features, lengths)

    sub = self.encoder_config.subsampling_factor
    sr = self.preprocessor_config.sample_rate
    hop = self.preprocessor_config.hop_length
    step = self._fast_step

    results = []
    for b in range(batch_size):
        features = batch_features[b:b + 1]
        max_length = int(lengths[b])
        max_len = mx.array(max_length, dtype=mx.int32)
        h, c = self._make_initial_decoder_state(1, features.dtype)
        t = mx.array(0, dtype=mx.int32)
        last = mx.array(self.blank_id, dtype=mx.int32)
        nsym = mx.array(0, dtype=mx.int32)
        idx = mx.array([0], dtype=mx.int32)
        t_host = 0
        hyp = []
        while t_host < max_length:
            toks, ts, durs = [], [], []
            for _ in range(_TDT_BLOCK):
                feature = mx.take(features, idx, axis=1)  # features[:, t:t+1]
                tok_out, t_at, dur, t, last, h, c, nsym, idx_next = step(feature, last, h, c, t, nsym, max_len)
                idx = idx_next.reshape(1)
                toks.append(tok_out)
                ts.append(t_at)
                durs.append(dur)
            vals = mx.stack(toks + ts + durs + [t]).tolist()  # the one host sync per block
            t_host = vals[-1]
            for k in range(_TDT_BLOCK):
                tok = vals[k]
                if tok < 0 or _tok.is_special_token(tok, self.vocabulary):
                    continue
                # mlx-audio's decode() uses this float expression order.
                hyp.append(_pk.AlignedToken(tok, start=vals[_TDT_BLOCK + k] * sub / sr * hop,
                                            duration=vals[2 * _TDT_BLOCK + k] * sub / sr * hop,
                                            text=_tok.decode([tok], self.vocabulary)))
        results.append(_pk.sentences_to_result(_pk.tokens_to_sentences(hyp)))
    return results

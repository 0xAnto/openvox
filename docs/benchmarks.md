# Why these models

OpenVox ships two models for Standard mode and one for Live mode. All three
come from local benchmarks on an Apple M1 with 8 GB memory, over 68 clips of
real and synthetic speech (7.6 minutes).

## Standard mode

Measured on 2026-09-30. One script ran every row: the same clips, the same
text normalization, and one process per model. MLX rows run with the MLX
buffer cache off, as the app does. WER is pooled over all words.

| Model | Level | WER | Final text, median / p95 | Memory held | Peak RAM |
| --- | --- | ---: | ---: | ---: | ---: |
| **Phonon-2, packed** | **Best** | 9.7% | 271 / 468 ms | 534 MB | 861 MB |
| Phonon-2, dense fp16 | — | 10.0% | 147 / 254 ms | 1327 MB | 1509 MB |
| Parakeet v2, bf16 | — | 10.0% | 380 / 601 ms | 1320 MB | 2040 MB |
| Moonshine medium | Best until this release | 13.8% | 336 / 802 ms | 568 MB | 710 MB |
| **Moonshine small** | **Balanced** | 14.5% | 196 / 417 ms | 216 MB | 510 MB |
| Moonshine tiny | Low until this release | 23.2% | 90 / 185 ms | 90 MB | 236 MB |

**Best runs Phonon-2.** It makes 30% fewer errors than Moonshine medium,
reaches final text sooner, and holds about the same memory. Phonon-2 is
NVIDIA's Parakeet TDT 0.6B v3 with its encoder weights retrained to five
values per row, so each weight fits in two 2-bit planes.

**Phonon-2 runs packed.** The dense form is about 120 ms faster, and it holds
2.5x the memory. Parakeet v2 is as accurate as Phonon-2, and it holds 2.5x
the memory too.

**Balanced stays on Moonshine small.** It is the only model near a
quarter-GB.

**Low is gone.** Moonshine tiny gets about one word in four wrong.

**Moonshine medium stays as a fallback only.** small ships ORT-format graphs,
which only the onnxruntime that wrote them can open. medium ships `.onnx`, so
the sidecar loads it when small will not open.

### Loading Phonon-2

The download is 164 MB. Fermion's loader decodes the whole file before it
packs anything, so it holds every layer's tables at once. OpenVox decodes one
layer at a time on the GPU, and saves the packed weights (334 MB) after the
first load. Later loads read that file. Both loaders give the same
parameters, bit for bit.

| Load | Fermion's loader | OpenVox |
| --- | ---: | ---: |
| First load after the download | 9.9 s, 2.7 GB peak | 4.5 s, 745 MB peak (once) |
| App launch | 9.9 s | 0.9 s |
| Reload after the 15-minute idle unload | 9.9 s | 0.18 s |

Of the 0.9 s at launch, 0.73 s is the `mlx_audio` import.

The Best level also installs its own runtime once: MLX, mlx-audio, and
transformers without torch. That adds 316 MB to the 128 MB base runtime.

### Long dictations

Phonon-2 decodes audio longer than 30 s in 30 s windows, with mlx-audio's
overlap merge. Shorter audio is one pass. The long clips join benchmark clips
with 0.5 s gaps.

| Dictation | One pass: WER, MLX peak | 30 s windows: WER, MLX peak |
| --- | ---: | ---: |
| 66 s | 5.4%, 1622 MB | 5.4%, 1097 MB |
| 185 s | 15.2%, 2002 MB | 12.0%, 1108 MB |
| 302 s | 12.0%, 2541 MB | 8.3%, 1119 MB |

## The first run

Measured on 2026-08-12 with the benchmark harness, over the same 68 clips.
This run picked the Live model and the first Standard model.

| Model | WER | Final text | Peak RAM |
| --- | ---: | ---: | ---: |
| Moonshine ONNX medium | 12.8% | 329 ms | 1.7 GB |
| **Nemotron Streaming EN** — Live mode | 12.0% | 294 ms | 3.7 GB |
| Parakeet v2 | 8.2% | 338 ms | 5.3 GB |
| MOSS Transcribe | 10.6% | 3190 ms | 2.9 GB |
| Qwen3 ASR 0.6B | 10.7% | 1620 ms | 3.5 GB |
| Moonshine PyTorch medium | 13.3% | 648 ms | 2.6 GB |
| Audio8 ASR 0.1B | 30.5% | 544 ms | 2.9 GB |

**Live mode uses Nemotron.** It is the only model that keeps up with live
speech on every clip, and it never rewrites a word it has shown. OpenVox types
into whichever app has focus, so a rewrite there breaks your undo stack.
Phonon-2 cannot replace it: it is an offline model, and its own live mode
decodes the whole segment again every 0.5 s, which rewrites words.

The harness scores some models differently from the script above: 12.8%
against 13.8% for Moonshine medium, and 8.2% against 10.0% for Parakeet v2.
Compare rows inside one table only.

The table predates v1.0.11, which cut Moonshine's memory and decode time. The
row keeps its original number, so the ranking stays one like-for-like run.
After that release, measured through the app on the same M1:

- Standard mode holds 796 MB idle and peaks at 997 MB over a session.
- A 58 s clip decodes in 15.6 s, against 24.9 s before.
- Two 58 s clips in a row hold 799 MB, against a 5947 MB peak before.

One machine, one run per model. The numbers rank these models against each
other. They do not reproduce published WER.

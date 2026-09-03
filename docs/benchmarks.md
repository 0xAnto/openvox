# Why these two models

OpenVox ships one model per mode. Both come from a local benchmark of seven
on-device speech models on an Apple M1 with 8 GB memory, over 68 clips of
real and synthetic speech.

| Model | WER | Final text | Peak RAM |
| --- | ---: | ---: | ---: |
| **Moonshine ONNX medium** — Fast mode | 12.8% | 329 ms | 1.7 GB |
| **Nemotron Streaming EN** — Streaming mode | 12.0% | 294 ms | 3.7 GB |
| Parakeet v2 | 8.2% | 338 ms | 5.3 GB |
| MOSS Transcribe | 10.6% | 3190 ms | 2.9 GB |
| Qwen3 ASR 0.6B | 10.7% | 1620 ms | 3.5 GB |
| Moonshine PyTorch medium | 13.3% | 648 ms | 2.6 GB |
| Audio8 ASR 0.1B | 30.5% | 544 ms | 2.9 GB |

**Fast mode uses Moonshine.** It reaches final text in 329 ms and holds 642 MB
warm, which is 3.5x smaller than anything of the same speed.

**Streaming mode uses Nemotron.** It is the only model that keeps up with live
speech on every clip, and it never rewrites a word it has shown. OpenVox types
into whichever app has focus, so a rewrite there breaks your undo stack.

**Parakeet is more accurate, and OpenVox does not ship it.** Its 5.3 GB peak is
most of an 8 GB machine.

One machine, one run per model. The numbers rank these models against each
other. They do not reproduce published WER.

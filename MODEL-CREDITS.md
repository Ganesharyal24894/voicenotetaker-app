# Model credits

The app's speech and speaker models are not ours. They are open models,
re-hosted unchanged as assets of the
[`models-v1`](https://github.com/Ganesharyal24894/voicenotetaker-app/releases/tag/models-v1)
release so a phone can fetch one file at a time instead of unpacking a
`.tar.bz2` on battery — see [`doc/models.md`](doc/models.md) for why.

**Re-hosted, not retrained.** We converted nothing and trained nothing. Every
file below is a byte-for-byte copy of an upstream artefact; the sha256s in
`lib/model/model_download.dart` are the upstream bytes' own.

All four licences permit redistribution, commercial use included.

---

## Hindi and Hinglish speech — AI4Bharat IndicConformer

| | |
|---|---|
| Files | `model.int8.onnx`, `tokens.txt` |
| Re-hosted from | [`meetsync/indic-conformer-onnx-sherpa`](https://huggingface.co/meetsync/indic-conformer-onnx-sherpa) |
| Original model | [`ai4bharat/indicconformer_stt_hi_hybrid_ctc_rnnt_large`](https://huggingface.co/ai4bharat/indicconformer_stt_hi_hybrid_ctc_rnnt_large) |
| Licence | **MIT**, on both the original and the ONNX conversion |

The ONNX conversion's own card states: *"This is an ONNX conversion of
AI4Bharat's Indic Conformer Large"*, and *"License: MIT (allows conversion,
modification, and redistribution)"*.

Attribution: **IndicConformer, by AI4Bharat (IIT Madras)**, used under the MIT
licence.

> **Citation, unverified.** AI4Bharat's model cards on Hugging Face are gated,
> so we could not read a BibTeX block from the card itself. The model is
> associated with *IndicVoices* (Javed et al., Findings of ACL 2024,
> [arXiv:2403.01926](https://arxiv.org/abs/2403.01926)). Anyone with access to
> the gated card should confirm the citation AI4Bharat actually asks for and
> replace this note.

## English speech — NVIDIA NeMo Parakeet TDT 110M

| | |
|---|---|
| Files | `encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt` |
| Re-hosted from | sherpa-onnx [`asr-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models), `sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8` |
| Original model | [`nvidia/parakeet-tdt_ctc-110m`](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) |
| Licence | **[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/)** |

The NVIDIA model card states, verbatim:

> License to use this model is covered by the CC-BY-4.0. By downloading the
> public and release version of the model, you accept the terms and conditions
> of the CC-BY-4.0 license.

Attribution, as CC-BY-4.0 requires — credit, licence link, and a statement of
changes:

> **Parakeet TDT CTC 110M**, © NVIDIA, built with NVIDIA NeMo and developed
> with Suno.ai. Licensed under
> [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). **Modified**: the
> TDT transducer branch was exported to ONNX and quantised to int8 by the
> sherpa-onnx project; we redistribute those files unchanged.

## Who said what, part 1 — pyannote segmentation-3.0

| | |
|---|---|
| File | `segmentation.onnx` (the FLOAT model, on purpose — its int8 export misses quiet speech) |
| Re-hosted from | sherpa-onnx [`speaker-segmentation-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models), `sherpa-onnx-pyannote-segmentation-3-0` |
| Original model | [`pyannote/segmentation-3.0`](https://huggingface.co/pyannote/segmentation-3.0) |
| Licence | **MIT** |

MIT permits redistribution of the ONNX conversion, with the copyright and
permission notice. The Hugging Face repository is *gated* — it asks for your
company and website before it will serve you the file — but that is an access
condition on their download page, not a licence term; the gate text itself says
the model *"uses MIT license and will always remain open-source"*.

The model card asks for two citations:

```bibtex
@inproceedings{Plaquet23,
  author={Alexis Plaquet and Hervé Bredin},
  title={{Powerset multi-class cross entropy loss for neural speaker diarization}},
  year=2023, booktitle={Proc. INTERSPEECH 2023},
}
@inproceedings{Bredin23,
  author={Hervé Bredin},
  title={{pyannote.audio 2.1 speaker diarization pipeline: principle, benchmark, and recipe}},
  year=2023, booktitle={Proc. INTERSPEECH 2023},
}
```

## Who said what, part 2 — 3D-Speaker CAM++

| | |
|---|---|
| File | `campplus.onnx` |
| Re-hosted from | sherpa-onnx [`speaker-recongition-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models), `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` |
| Original model | [`iic/speech_campplus_sv_zh_en_16k-common_advanced`](https://modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced) on ModelScope |
| Licence | **Apache-2.0**, both the [3D-Speaker project](https://github.com/modelscope/3D-Speaker/blob/main/LICENSE) and the weights |

The project asks that you cite it:

```bibtex
@article{chen20243d,
  title={3D-Speaker-Toolkit: An Open Source Toolkit for Multi-modal Speaker Verification and Diarization},
  author={Chen, Yafeng and Zheng, Siqi and Wang, Hui and Cheng, Luyao and others},
  booktitle={ICASSP}, year={2025}
}
```

## The converter — sherpa-onnx

Every file except the Hindi one reaches us through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (k2-fsa), **Apache-2.0**,
which did the ONNX export and the int8 quantisation. The app also uses
sherpa-onnx at runtime to load these models. The upstream model licences above
apply on top of it.

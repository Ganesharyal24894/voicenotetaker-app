#!/usr/bin/env python3
"""
Regenerate the cross-language ADPCM golden vectors.

The Dart decoder in `lib/services/codec/adpcm_decoder.dart` must reproduce the
firmware's codec exactly. A mismatch does not fail loudly - it degrades audio
silently - so the ground truth is taken from the SAME Python reference the
firmware was validated against, and checked in as JSON.

Usage (from the repository root):

    /home/ganesh/personalProjects/nrf52840-sense/host/.venv/bin/python \
        tool/generate_adpcm_fixtures.py

Override the reference location with --reference if the firmware repo moves.
Output: test/fixtures/adpcm_vectors.json
"""

import argparse
import importlib.util
import json
import math
import pathlib
import random
import struct
import sys

DEFAULT_REFERENCE = pathlib.Path(
    "/home/ganesh/personalProjects/nrf52840-sense/host/adpcm.py"
)
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "test" / "fixtures" / "adpcm_vectors.json"

SAMPLES_PER_BLOCK = 320  # firmware block size -> 4 + 160 = 164 bytes on air


def load_reference(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("adpcm_reference", path)
    if spec is None or spec.loader is None:
        sys.exit(f"could not load reference decoder from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def block(predictor: int, index: int, nibbles: list[int]) -> bytes:
    """Hand-build a block from an explicit nibble list, LOW NIBBLE FIRST."""
    out = bytearray(struct.pack("<hBB", predictor, index, 0))
    padded = nibbles + [0] * (len(nibbles) % 2)
    for lo, hi in zip(padded[0::2], padded[1::2]):
        out.append((lo & 0x0F) | ((hi & 0x0F) << 4))
    return bytes(out)


def build_cases(ref) -> list[dict]:
    """Each case is raw block bytes plus a note on what it is probing."""
    rng = random.Random(20260910)
    cases: list[tuple[str, str, bytes]] = []

    def encoded(name, note, samples, predictor=0, index=0):
        data, _, _ = ref.encode_block(samples, predictor, index)
        cases.append((name, note, data))

    # --- realistic payloads, full 320-sample firmware blocks -----------------
    speech = [
        int(8000 * math.sin(2 * math.pi * 440 * n / 16000)
            + 2500 * math.sin(2 * math.pi * 1300 * n / 16000))
        for n in range(SAMPLES_PER_BLOCK)
    ]
    encoded("tone_320", "full 164-byte firmware block, two summed tones", speech)
    encoded("silence_320", "all-zero input, 320 samples", [0] * SAMPLES_PER_BLOCK)
    encoded(
        "noise_320",
        "white noise, exercises the whole step table",
        [rng.randint(-30000, 30000) for _ in range(SAMPLES_PER_BLOCK)],
    )

    # --- clamping at the table bounds ---------------------------------------
    cases.append((
        "step_index_clamp_low",
        "starts at index 0 and sends code 0 repeatedly; index must stay >= 0",
        block(0, 0, [0] * 32),
    ))
    cases.append((
        "step_index_clamp_low_active",
        "index pinned at 0 while the predictor still moves; proves the clamp "
        "holds without freezing output",
        block(500, 0, [1, 9] * 16),
    ))
    cases.append((
        "step_index_clamp_high",
        "starts at index 88 and sends code 7 repeatedly; index must stay <= 88",
        block(0, 88, [7] * 32),
    ))
    cases.append((
        "step_index_header_above_max",
        "header index 200 is out of range and must be clamped to 88 on entry",
        block(0, 200, [7, 15, 7, 15, 0, 8]),
    ))
    cases.append((
        "predictor_clamp_positive",
        "large positive deltas at max step; predictor saturates at +32767",
        block(30000, 88, [7] * 40),
    ))
    cases.append((
        "predictor_clamp_negative",
        "large negative deltas at max step; predictor saturates at -32768",
        block(-30000, 88, [15] * 40),
    ))
    cases.append((
        "predictor_header_extremes",
        "header predictor at int16 bounds round-trips through the LE header",
        block(-32768, 40, [15, 7, 0, 8, 4, 12]),
    ))

    # --- nibble ordering ----------------------------------------------------
    cases.append((
        "nibble_order_probe",
        "asymmetric nibble pairs; swapping low/high changes every sample",
        block(0, 0, [0, 15, 1, 14, 2, 13, 3, 12, 7, 8]),
    ))
    cases.append((
        "single_byte_two_nibbles",
        "one payload byte -> exactly two samples, low nibble decoded first",
        block(100, 5, [3, 11]),
    ))

    # --- odd sample counts and independence ---------------------------------
    encoded(
        "odd_five_samples",
        "5 samples pack into 3 bytes; decode yields 6, last one is padding",
        [1000, -2000, 3000, -4000, 5000],
    )
    encoded("odd_one_sample", "1 sample -> 1 byte -> 2 decoded samples", [1234])
    cases.append((
        "empty_payload",
        "header only, no nibbles: decodes to nothing",
        block(1234, 7, []),
    ))
    cases.append((
        "header_only_truncated",
        "3 bytes is shorter than the header; decoder must return nothing",
        b"\x01\x02\x03",
    ))

    # Same nibbles, different headers: proves each block stands alone.
    payload = [5, 10, 3, 12, 0, 15, 8, 1]
    cases.append((
        "independent_block_a",
        "identical nibbles to independent_block_b but a different header",
        block(0, 0, payload),
    ))
    cases.append((
        "independent_block_b",
        "identical nibbles to independent_block_a but a different header",
        block(-5000, 40, payload),
    ))

    # --- randomised blocks --------------------------------------------------
    for i in range(4):
        cases.append((
            f"random_block_{i}",
            "randomised header and nibbles",
            block(
                rng.randint(-32768, 32767),
                rng.randint(0, 88),
                [rng.randint(0, 15) for _ in range(SAMPLES_PER_BLOCK)],
            ),
        ))

    out = []
    for name, note, data in cases:
        out.append({
            "name": name,
            "note": note,
            "block_hex": data.hex(),
            "expected_samples": ref.decode_block(data),
        })
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", type=pathlib.Path, default=DEFAULT_REFERENCE)
    ap.add_argument("--output", type=pathlib.Path, default=OUTPUT)
    args = ap.parse_args()

    if not args.reference.exists():
        sys.exit(f"reference decoder not found: {args.reference}")

    ref = load_reference(args.reference)
    cases = build_cases(ref)

    document = {
        "_comment": "GENERATED - do not edit by hand. "
                    "Run tool/generate_adpcm_fixtures.py to regenerate.",
        "generator": "tool/generate_adpcm_fixtures.py",
        "reference": str(args.reference),
        "samples_per_block": SAMPLES_PER_BLOCK,
        "step_table": ref.STEP_TABLE,
        "index_table": ref.INDEX_TABLE,
        "cases": cases,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=1) + "\n")
    total = sum(len(c["expected_samples"]) for c in cases)
    print(f"wrote {args.output} ({len(cases)} cases, {total} golden samples)")


if __name__ == "__main__":
    main()

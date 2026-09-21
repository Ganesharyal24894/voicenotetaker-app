# opus_native — vendored libopus decoder

| | |
|---|---|
| Upstream | libopus **1.5.2** |
| Taken from | `opus.tar.gz`, sha256 `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1` — the same tarball the firmware's `voiceNotetaker/lib/opus/` came from |
| Modified? | **No.** Every file under `third_party/libopus/` is byte-identical to upstream. |
| Licence | BSD 3-clause, `third_party/libopus/COPYING` |
| Ours | `README.md`, `pubspec.yaml`, `hook/build.dart`, `lib/opus_native.dart` |

**What was taken:** the decoder only — 63 `.c` files (CELT, the SILK decoder,
`src/opus.c`, `src/opus_decoder.c`) and the headers they include. The
standard decoder API links SILK although the device's CELT-only stream never
runs it. `celt/entenc.c` is the one encoder file, because `celt/bands.c`
references `ec_encode`. No encoder, no `dnn/` (DRED/LPCNet), no multistream,
no `arm/`, `x86/` or `mips/` code.

**How it is built:** `hook/build.dart`, a Dart build hook, compiles those
sources with the target's own toolchain whenever the app is built or tested —
float, portable C, `OPUS_BUILD VAR_ARRAYS HAVE_LRINTF HAVE_LRINT`. Why float
when the firmware is fixed point, and why no SIMD, is written at the top of
that file.

**To update:** replace `third_party/libopus/` from a new upstream tarball,
keeping the same file list (`find third_party/libopus -type f`), record its
sha256 above, and run `tool/flutter_test.sh test/codec/` — the golden test
checks the loaded version string, so it will say which version it is testing.

// Compiles the vendored libopus 1.5.2 DECODER into this package's code asset.
//
// One source of truth for every platform: the same unmodified C files, the
// same defines, built by the platform's own toolchain - the NDK for Android,
// Xcode for iOS, the host compiler for `flutter test`. So the decoder the
// tests exercise is the decoder the phone runs, not the host's system libopus.
//
// FLOAT, NOT FIXED POINT - measured, and against the firmware's own choice.
// The firmware encodes in fixed point because the nRF52840 has no double FPU.
// The phone decodes in float because libopus 1.5.2's fixed-point packet loss
// concealment conceals a speech frame as near-silence at 84 of 230 loss
// positions in real speech (concealed/true energy < 0.1), against 0 of 230 in
// float; see test/fixtures/opus_vectors.json, `float_decoder.plc_scan`. The WER
// that justified Opus under 3 % loss was also measured through a float decoder.
// The bitstream is the same either way: Opus is decoded, not matched.
//
// Portable C only: no SIMD and no run-time CPU detection (no OPUS_HAVE_RTCD,
// no OPUS_X86_* / OPUS_ARM_*), so there is one code path on every phone and
// nothing to select at run time. Decoding 50 frames a second is not where a
// phone's CPU goes.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _root = 'third_party/libopus';

/// Every `.c` file under third_party/libopus, and nothing else there.
///
/// The decoder half of CELT, the SILK decoder (the standard decoder API links
/// SILK even though the device's CELT-only stream never runs it), and
/// src/opus.c + src/opus_decoder.c. No encoder, no DNN/DRED, no multistream.
const _sources = <String>[
  '$_root/celt/bands.c',
  '$_root/celt/celt.c',
  '$_root/celt/celt_decoder.c',
  '$_root/celt/celt_lpc.c',
  '$_root/celt/cwrs.c',
  '$_root/celt/entcode.c',
  '$_root/celt/entdec.c',
  '$_root/celt/entenc.c',
  '$_root/celt/kiss_fft.c',
  '$_root/celt/laplace.c',
  '$_root/celt/mathops.c',
  '$_root/celt/mdct.c',
  '$_root/celt/modes.c',
  '$_root/celt/pitch.c',
  '$_root/celt/quant_bands.c',
  '$_root/celt/rate.c',
  '$_root/celt/vq.c',
  '$_root/silk/bwexpander_32.c',
  '$_root/silk/bwexpander.c',
  '$_root/silk/CNG.c',
  '$_root/silk/code_signs.c',
  '$_root/silk/dec_API.c',
  '$_root/silk/decode_core.c',
  '$_root/silk/decode_frame.c',
  '$_root/silk/decode_indices.c',
  '$_root/silk/decode_parameters.c',
  '$_root/silk/decode_pitch.c',
  '$_root/silk/decode_pulses.c',
  '$_root/silk/decoder_set_fs.c',
  '$_root/silk/gain_quant.c',
  '$_root/silk/init_decoder.c',
  '$_root/silk/lin2log.c',
  '$_root/silk/log2lin.c',
  '$_root/silk/LPC_analysis_filter.c',
  '$_root/silk/LPC_fit.c',
  '$_root/silk/LPC_inv_pred_gain.c',
  '$_root/silk/NLSF2A.c',
  '$_root/silk/NLSF_decode.c',
  '$_root/silk/NLSF_stabilize.c',
  '$_root/silk/NLSF_unpack.c',
  '$_root/silk/pitch_est_tables.c',
  '$_root/silk/PLC.c',
  '$_root/silk/resampler.c',
  '$_root/silk/resampler_private_AR2.c',
  '$_root/silk/resampler_private_down_FIR.c',
  '$_root/silk/resampler_private_IIR_FIR.c',
  '$_root/silk/resampler_private_up2_HQ.c',
  '$_root/silk/resampler_rom.c',
  '$_root/silk/shell_coder.c',
  '$_root/silk/sort.c',
  '$_root/silk/stereo_decode_pred.c',
  '$_root/silk/stereo_MS_to_LR.c',
  '$_root/silk/sum_sqr_shift.c',
  '$_root/silk/table_LSF_cos.c',
  '$_root/silk/tables_gain.c',
  '$_root/silk/tables_LTP.c',
  '$_root/silk/tables_NLSF_CB_NB_MB.c',
  '$_root/silk/tables_NLSF_CB_WB.c',
  '$_root/silk/tables_other.c',
  '$_root/silk/tables_pitch_lag.c',
  '$_root/silk/tables_pulses_per_block.c',
  '$_root/src/opus.c',
  '$_root/src/opus_decoder.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    _refuseCcacheShim(input.config.code);
    await CBuilder.library(
      name: 'opus_native',
      // The Dart library whose @Native declarations resolve against this.
      assetName: 'opus_native.dart',
      sources: _sources,
      includes: const [
        '$_root/include',
        '$_root/celt',
        '$_root/silk',
        '$_root/src',
      ],
      defines: const {
        'OPUS_BUILD': null,
        // C99 variable-length arrays for libopus's scratch, as the firmware
        // uses. The decoder's frames are small; no alloca, no heap.
        'VAR_ARRAYS': null,
        // lrintf for float -> int16, as upstream's configure detects. Without
        // it libopus falls back to floor(x + .5), which rounds differently.
        'HAVE_LRINTF': null,
        'HAVE_LRINT': null,
        // celt/celt.c builds opus_get_version_string() from this.
        'PACKAGE_VERSION': '"1.5.2"',
      },
      // cos/exp/log live in libm. The C driver links libc and libdl but not
      // libm, and a shared library may leave symbols undefined - so without
      // this the Android .so BUILDS, lists no libm.so in NEEDED, and fails in
      // the dynamic loader on a phone ("cannot locate symbol cos"). The host
      // tests cannot notice: the test process already has libm loaded. Found
      // by reading the APK's .so, not by running it.
      libraries: const ['m'],
      // The same code in debug and release: libopus reads none of these.
      buildModeDefine: false,
    ).run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.WARNING
        ..onRecord.listen((record) => stderr.writeln(record.message)),
    );
  });
}

/// THE ONE HOST PROBLEM THIS HOOK HAS, said in a sentence instead of a
/// compiler error.
///
/// For `flutter test` Flutter passes no compiler, so native_toolchain_c runs
/// `which clang` and follows the symlink. With Debian's ccache shim directory
/// (`/usr/lib/ccache`) ahead of `/usr/bin` on PATH, that lands on the ccache
/// binary itself, which is then invoked AS clang and fails with
/// "ccache: invalid option -- 'f'" - taking every test in the suite down with
/// it. Android and iOS builds are unaffected: Flutter hands those the NDK's
/// and Xcode's compilers explicitly.
void _refuseCcacheShim(CodeConfig code) {
  if (code.targetOS != OS.linux || code.cCompiler != null) return;
  final String found;
  final String resolved;
  try {
    final which = Process.runSync('which', ['clang']);
    if (which.exitCode != 0) return;
    found = (which.stdout as String).trim();
    resolved = File(found).resolveSymbolicLinksSync();
  } on Exception {
    // No `which`, or a dangling link: not the problem this guards against,
    // so let native_toolchain_c report whatever it finds.
    return;
  }
  if (!resolved.endsWith('/ccache')) return;
  throw StateError(
    'opus_native: `clang` on PATH is the ccache shim ($found -> $resolved), '
    'which native_toolchain_c cannot drive. Run the tests through '
    'tool/flutter_test.sh, or put /usr/bin ahead of /usr/lib/ccache on PATH.',
  );
}

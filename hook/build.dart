import 'dart:io';

import 'package:native_toolchain_ninja/native_toolchain_ninja.dart';
import 'package:code_assets/code_assets.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

/// The flags `pkg-config` reports for [packageName], or null when `pkg-config`
/// or the package is not installed.
Future<List<String>?> _pkgConfig(String flag, String packageName) async {
  final ProcessResult result;
  try {
    result = await Process.run('pkg-config', [flag, packageName]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return (result.stdout as String)
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;

    if (!input.config.buildCodeAssets) {
      return;
    }

    final debugBuild = false;

    NinjaBuilder? ninjaBuilder;

    if (input.config.code.targetOS == OS.macOS) {
      ninjaBuilder = NinjaBuilder.library(
        name: packageName,
        assetName: 'macos',
        sources: ['src/macos.m', 'src/window_buttons_proxy.m'],
        language: Language.objectiveC,
        frameworks: ['AppKit', 'QuartzCore'],
        flags: [
          // ignore: dead_code
          if (debugBuild) ...['-O0', '-g3'],
          "-fobjc-arc",
        ],
      );
    } else if (input.config.code.targetOS == OS.linux) {
      // A Linux host without the GTK development files (a CI container
      // running tests) gets no asset instead of a failed build: the symbols
      // are only resolved when a window is actually created.
      final gtkFlags = await _pkgConfig('--cflags', 'gtk+-3.0');
      if (gtkFlags == null) {
        // ignore: avoid_print
        print(
          'window_toolbox: gtk+-3.0 is not installed, skipping the Linux asset',
        );
        return;
      }
      ninjaBuilder = NinjaBuilder.library(
        name: packageName,
        assetName: 'linux',
        sources: ['src/linux.c'],
        buildMode: BuildMode.debug,
        optimizationLevel: OptimizationLevel.o0,
        flags: [
          // ignore: dead_code
          if (debugBuild) ...['-g'],
          ...gtkFlags,
        ],
        language: Language.c,
        libraries: [
          // Everything we need will be linked into the final executable.
        ],
      );
    }

    if (ninjaBuilder != null) {
      await ninjaBuilder.run(
        input: input,
        output: output,
        logger: Logger('')
          ..level = .ALL
          // ignore: avoid_print
          ..onRecord.listen((record) => print(record.message)),
      );
    }
  });
}

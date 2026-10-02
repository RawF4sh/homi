import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class AppAppearance extends ValueNotifier<ThemeMode> {
  AppAppearance({Future<File> Function()? file})
    : _file = file ?? _defaultFile,
      super(ThemeMode.system);

  static final instance = AppAppearance();

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/appearance');

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final name = (await file.readAsString()).trim();
      value = ThemeMode.values.firstWhere(
        (mode) => mode.name == name,
        orElse: () => ThemeMode.system,
      );
    } catch (_) {
      // ignore: empty_catches
    }
  }

  Future<void> choose(ThemeMode mode) async {
    value = mode;
    try {
      await (await _file()).writeAsString(mode.name, flush: true);
    } catch (_) {
      // ignore: empty_catches
    }
  }
}

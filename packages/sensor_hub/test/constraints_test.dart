import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  List<File> sourceFiles = [];
  for (FileSystemEntity entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      sourceFiles.add(entity);
    }
  }

  test('module source files found', () {
    expect(sourceFiles, isNotEmpty);
  });

  for (File file in sourceFiles) {
    test('${file.path} follows the rules', () {
      String code = '';
      for (String line in file.readAsLinesSync()) {
        if (!line.trimLeft().startsWith('//')) {
          code += '$line\n';
        }
      }
      expect(code, isNot(contains('package:flutter/widgets.dart')), reason: 'no widgets dependency');
      expect(code, isNot(contains('package:flutter/material.dart')));
      expect(code, isNot(contains('package:flutter/cupertino.dart')));
      expect(code, isNot(contains('WidgetsBindingObserver')));
      expect(code, isNot(contains('dart:mirrors')));
      expect(code, isNot(contains(RegExp(r'\bcompute\s*\('))));
      expect(code, isNot(contains('EventChannel')));
    });
  }

  test('no pub.dev dependencies, only the Flutter SDK', () {
    String pubspec = File('pubspec.yaml').readAsStringSync();
    String dependencies = pubspec.split('dependencies:')[1].split('dev_dependencies:')[0];
    List<String> names = [];
    for (RegExpMatch match in RegExp(r'^  (\w+):', multiLine: true).allMatches(dependencies)) {
      names.add(match.group(1)!);
    }
    expect(names, ['flutter']);
  });
}

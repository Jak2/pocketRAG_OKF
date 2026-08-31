import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/theme/app_theme.dart';

void main() {
  // appThemeData() resolves a GoogleFonts family, which reaches for the asset
  // bundle. Without a binding that throws before any assertion runs.
  TestWidgetsFlutterBinding.ensureInitialized();

  // The palette is a mutable global, so every test restores it — a leaked
  // light theme would make an unrelated later test read the wrong colours.
  tearDown(() => applyThemeMode(true));

  group('palette', () {
    test('every field differs between the two themes', () {
      // A field defined in only one palette is the failure mode this guards:
      // it renders correctly in the theme it was written for and invisibly in
      // the other.
      applyThemeMode(true);
      final dark = appPalette;
      applyThemeMode(false);
      final light = appPalette;

      expect(dark.bg, isNot(light.bg));
      expect(dark.fg, isNot(light.fg));
      expect(dark.surface, isNot(light.surface));
      expect(dark.surfaceAlt, isNot(light.surfaceAlt));
      expect(dark.border, isNot(light.border));
      expect(dark.accent, isNot(light.accent));
      expect(dark.onAccent, isNot(light.onAccent));
    });

    test('AppColors follows the live palette rather than a captured value', () {
      applyThemeMode(true);
      final darkBg = AppColors.bg;
      applyThemeMode(false);

      expect(AppColors.bg, isNot(darkBg));
      expect(AppColors.bg, kLightPalette.bg);
      expect(appIsDark, isFalse);
    });

    test('foreground and background are never the same colour in either theme', () {
      for (final dark in [true, false]) {
        applyThemeMode(dark);
        expect(AppColors.fg, isNot(AppColors.bg), reason: 'dark=$dark');
        expect(AppColors.onAccent, isNot(AppColors.accent), reason: 'dark=$dark');
      }
    });

    test('the theme data brightness matches the palette', () {
      applyThemeMode(false);
      expect(appThemeData().brightness, Brightness.light);
      expect(appThemeData().scaffoldBackgroundColor, kLightPalette.bg);

      applyThemeMode(true);
      expect(appThemeData().brightness, Brightness.dark);
      expect(appThemeData().scaffoldBackgroundColor, kDarkPalette.bg);
    });
  });
}

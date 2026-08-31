// lib/theme/app_theme.dart
//
// The visual system from `design/Pocket RAG.dc.html`. Two palettes, one set of
// names: every screen reads `AppColors.x` and never asks which theme is live.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// One resolved palette. Both themes define every field, so no screen can be
/// correct in one theme and broken in the other.
class AppPalette {
  /// Page background.
  final Color bg;

  /// Raised surfaces: the user's message bubble, the composer field, the
  /// expanded routing panel.
  final Color surface;

  /// A second surface a step away from [surface], for a panel sitting on one.
  final Color surfaceAlt;

  /// Primary text.
  final Color fg;

  /// Secondary text — labels, metadata, anything the eye should skip.
  final Color muted;

  /// Tertiary text, at the edge of legible. Timestamps, placeholder counts.
  final Color faint;

  /// Hairline borders. The design has no 2px rule and no shadows.
  final Color border;

  /// A stronger hairline, for the element that currently has focus.
  final Color borderStrong;

  /// The one accent. Used for the active mode, the send button, the index
  /// progress bar, and nothing decorative.
  final Color accent;

  /// Accent text on a dark ground — the retry control's label.
  final Color accentText;

  /// Foreground on top of a filled [accent] surface.
  final Color onAccent;

  const AppPalette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.fg,
    required this.muted,
    required this.faint,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accentText,
    required this.onAccent,
  });
}

const AppPalette kDarkPalette = AppPalette(
  bg: Color(0xFF121212),
  surface: Color(0xFF1E1E1E),
  surfaceAlt: Color(0xFF17171A),
  fg: Color(0xFFECECEA),
  muted: Color(0x8CFFFFFF), // white 55%
  faint: Color(0x66FFFFFF), // white 40%
  border: Color(0x1AFFFFFF), // white 10%
  borderStrong: Color(0x29FFFFFF), // white 16%
  accent: Color(0xFF5B8DEF),
  accentText: Color(0xFF8FB3F5),
  onAccent: Color(0xFF0B1220),
);

const AppPalette kLightPalette = AppPalette(
  bg: Color(0xFFFAFAF8),
  surface: Color(0xFFF0EFEC),
  surfaceAlt: Color(0xFFF5F4F1),
  fg: Color(0xFF17171A),
  muted: Color(0x8C000000),
  faint: Color(0x73000000),
  border: Color(0x14000000),
  borderStrong: Color(0x29000000),
  accent: Color(0xFF3D6FD9),
  accentText: Color(0xFF3D6FD9),
  onAccent: Color(0xFFFAFAF8),
);

/// The live palette.
///
/// A mutable global rather than a `Theme.of(context)` lookup: every existing
/// screen already reads `AppColors.x` statically, and threading a context
/// through every helper would be a larger change than the feature is worth.
/// [applyThemeMode] swaps it and the app rebuilds from the root.
AppPalette _palette = kDarkPalette;

/// Current palette, for code that wants the whole thing rather than one colour.
AppPalette get appPalette => _palette;

bool get appIsDark => identical(_palette, kDarkPalette);

/// Swaps the live palette. Callers must trigger a rebuild from above every
/// screen — [PocketRagApp] does this by rebuilding on a theme change.
void applyThemeMode(bool dark) => _palette = dark ? kDarkPalette : kLightPalette;

/// Named colours, resolved against whichever palette is live.
///
/// Deliberately not `const`: these used to be compile-time constants of a
/// single dark theme, and every call site still reads them the same way.
class AppColors {
  static Color get bg => _palette.bg;
  static Color get fg => _palette.fg;
  static Color get muted => _palette.muted;
  static Color get faint => _palette.faint;
  static Color get divider => _palette.border;
  static Color get border => _palette.border;
  static Color get borderStrong => _palette.borderStrong;
  static Color get surfaceMuted => _palette.surface;
  static Color get surfaceAlt => _palette.surfaceAlt;
  static Color get accent => _palette.accent;
  static Color get accentText => _palette.accentText;
  static Color get onAccent => _palette.onAccent;
}

TextStyle appHeading({double size = 24, FontWeight weight = FontWeight.w600, Color? color}) {
  return GoogleFonts.inter(fontSize: size, fontWeight: weight, color: color ?? AppColors.fg);
}

TextStyle appBody({
  double size = 14.5,
  Color? color,
  FontWeight weight = FontWeight.w400,
  double? height,
}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    color: color ?? AppColors.fg,
    height: height,
  );
}

TextStyle appMono({
  double size = 12,
  Color? color,
  FontWeight weight = FontWeight.w500,
  double? height,
}) {
  return GoogleFonts.jetBrainsMono(
    fontSize: size,
    fontWeight: weight,
    color: color ?? AppColors.fg,
    height: height,
  );
}

/// A small all-caps section label — the `MODEL` / `SKILLS` / `DIAGNOSTICS`
/// headers that structure the Config screen.
TextStyle appSectionLabel() => GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: AppColors.faint,
      letterSpacing: 0.55,
    );

ThemeData appThemeData() {
  final dark = appIsDark;
  return ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: GoogleFonts.inter().fontFamily,
    colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
      surface: AppColors.bg,
      primary: AppColors.accent,
      onPrimary: AppColors.onAccent,
    ),
    dividerColor: AppColors.divider,
  );
}

Widget appBorderedField({
  required TextEditingController controller,
  required String hint,
  bool obscure = false,
  int maxLines = 1,
  TextInputType? keyboardType,
  bool enabled = true,
  ValueChanged<String>? onChanged,
  Widget? suffix,
}) {
  OutlineInputBorder border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color),
      );

  return TextField(
    controller: controller,
    obscureText: obscure,
    maxLines: maxLines,
    keyboardType: keyboardType,
    enabled: enabled,
    onChanged: onChanged,
    style: appBody(size: 13.5),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: appBody(size: 13.5, color: AppColors.faint),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(AppColors.border),
      enabledBorder: border(AppColors.border),
      focusedBorder: border(AppColors.accent),
      disabledBorder: border(AppColors.border),
    ),
  );
}

Widget appPrimaryButton({required String label, required VoidCallback? onPressed}) {
  final enabled = onPressed != null;
  return SizedBox(
    width: double.infinity,
    child: TextButton(
      onPressed: enabled
          ? () {
              HapticFeedback.selectionClick();
              onPressed();
            }
          : null,
      style: TextButton.styleFrom(
        backgroundColor: enabled ? AppColors.accent : AppColors.surfaceMuted,
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
      ),
      child: Text(
        label,
        style: appBody(
          size: 15,
          weight: FontWeight.w600,
          color: enabled ? AppColors.onAccent : AppColors.faint,
        ),
      ),
    ),
  );
}

Widget appSecondaryButton({required String label, required VoidCallback? onPressed}) {
  final enabled = onPressed != null;
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: enabled
          ? () {
              HapticFeedback.selectionClick();
              onPressed();
            }
          : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 13),
        side: BorderSide(color: enabled ? AppColors.borderStrong : AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
      ),
      child: Text(
        label,
        style: appBody(
          size: 13.5,
          weight: FontWeight.w600,
          color: enabled ? AppColors.fg : AppColors.faint,
        ),
      ),
    ),
  );
}

Widget appStepper({
  required String label,
  required int value,
  required int min,
  required int max,
  required ValueChanged<int> onChanged,
}) {
  void step(int delta) {
    HapticFeedback.selectionClick();
    onChanged(value + delta);
  }

  return Row(
    children: [
      Expanded(child: Text(label, style: appBody(size: 13.5))),
      appIconCircleButton(
        icon: Icons.chevron_left,
        onPressed: value <= min ? null : () => step(-1),
      ),
      SizedBox(
        width: 44,
        child: Text(
          '$value',
          textAlign: TextAlign.center,
          style: appMono(size: 16, weight: FontWeight.w700),
        ),
      ),
      appIconCircleButton(
        icon: Icons.chevron_right,
        onPressed: value >= max ? null : () => step(1),
      ),
    ],
  );
}
/// A small circular icon button. Used by [appStepper]; not a general-purpose
/// control — the design puts a filled accent circle only on the send action.
Widget appIconCircleButton({required IconData icon, required VoidCallback? onPressed}) {
  final enabled = onPressed != null;
  return SizedBox(
    width: 36,
    height: 36,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        side: BorderSide(color: enabled ? AppColors.borderStrong : AppColors.border),
        shape: const CircleBorder(),
      ),
      child: Icon(icon, size: 17, color: enabled ? AppColors.fg : AppColors.faint),
    ),
  );
}

/// Keeps [controllers] alive for exactly as long as the route that builds this
/// widget, and disposes them in [State.dispose].
///
/// Dialog helpers used to create a controller, `await showDialog(...)`, then
/// dispose it in a `finally`. That future completes at `Navigator.pop`, but the
/// popped route keeps its subtree mounted and updating through the close
/// animation — a focused field re-listens to its controller mid-animation and
/// hits "A TextEditingController was used after being disposed", which cascades
/// into the `_dependents.isEmpty` assert and a red screen.
///
/// Wrap the dialog's content in this and drop the `finally`: Flutter calls
/// [State.dispose] only once the route is fully gone, animation included.
/// Reading `controller.text` right after the `await` is still fine — that runs
/// in the same turn as the pop, many frames before disposal.
class DisposeWithRoute extends StatefulWidget {
  const DisposeWithRoute({super.key, required this.controllers, required this.child});

  final List<TextEditingController> controllers;
  final Widget child;

  @override
  State<DisposeWithRoute> createState() => _DisposeWithRouteState();
}

class _DisposeWithRouteState extends State<DisposeWithRoute> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

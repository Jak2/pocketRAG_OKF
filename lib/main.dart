// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'instructions/instruction_library.dart';
import 'settings/engine_settings.dart';
import 'instructions/starter_personas.dart';
import 'secrets/secret_store.dart';
import 'theme/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/root_screen.dart';

const _keyOnboarded = 'onboarded';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
  await seedStarterPersonasIfEmpty(personasLibrary, rootBundle.loadString);

  // Resolve the palette before the first frame. Painting dark and then
  // repainting light is a visible flash on every cold start.
  final prefs = await SharedPreferences.getInstance();
  applyThemeMode((await EngineSettings.load(prefs)).themeMode != 'light');

  runApp(const PocketRagApp());
}

/// Rebuilds the whole app when the palette is swapped.
///
/// `AppColors` is a set of global getters rather than an inherited widget, so
/// nothing under here re-reads it on its own — the root has to rebuild for a
/// theme change to reach anything.
class ThemeScope extends InheritedWidget {
  final VoidCallback onThemeChanged;

  const ThemeScope({super.key, required this.onThemeChanged, required super.child});

  static ThemeScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>();

  @override
  bool updateShouldNotify(ThemeScope oldWidget) => false;
}

class PocketRagApp extends StatefulWidget {
  const PocketRagApp({super.key});

  @override
  State<PocketRagApp> createState() => _PocketRagAppState();
}

class _PocketRagAppState extends State<PocketRagApp> {
  final _secretStore = SecureSecretStore();

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      onThemeChanged: () => setState(() {}),
      child: MaterialApp(
        title: 'Pocket RAG',
        theme: appThemeData(),
        home: _AppEntry(secretStore: _secretStore),
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  final SecretStore secretStore;
  const _AppEntry({required this.secretStore});

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _onboarded = prefs.getBool(_keyOnboarded) ?? false);
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOnboarded, true);
    if (mounted) setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_onboarded!) {
      return OnboardingScreen(secretStore: widget.secretStore, onFinished: _finishOnboarding);
    }
    return RootScreen(secretStore: widget.secretStore);
  }
}

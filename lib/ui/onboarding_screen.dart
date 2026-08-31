// lib/ui/onboarding_screen.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  final SecretStore secretStore;
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.secretStore, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { bundle, llm }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.bundle;

  final _endpointController = TextEditingController(
    text: 'https://api.openai.com/v1/chat/completions',
  );
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: 'gpt-4o-mini');
  final _headersController = TextEditingController();
  EngineChoice _engineChoice = EngineChoice.cloud;
  String _onDeviceModelPath = '';

  String _okfBundlePath = '';
  int? _mdCount;
  String? _bundleError;

  @override
  void dispose() {
    _endpointController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _headersController.dispose();
    super.dispose();
  }

  Future<void> _pickBundleFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    setState(() {
      _okfBundlePath = path;
      _mdCount = null;
      _bundleError = null;
    });
    try {
      // Counting the markdown files is the whole preview: it is the one signal
      // that says "this folder is the bundle you meant" before setup ends.
      final count = await Directory(path)
          .list(recursive: true, followLinks: false)
          .where((e) => e is File && e.path.toLowerCase().endsWith('.md'))
          .length;
      if (mounted) setState(() => _mdCount = count);
    } catch (e) {
      if (mounted) setState(() => _bundleError = 'Could not read that folder: $e');
    }
  }

  Future<void> _pickOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) setState(() => _onDeviceModelPath = path);
  }

  Future<void> _next() async {
    if (_step == _Step.llm) {
      await _persistAndFinish();
      return;
    }
    setState(() => _step = _Step.values[_step.index + 1]);
  }

  Future<void> _skip() => _persistAndFinish();

  Future<void> _persistAndFinish() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = EngineSettings(
      choice: _engineChoice,
      cloudEndpoint: _endpointController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
      onDeviceModelPath: _onDeviceModelPath,
      okfBundlePath: _okfBundlePath,
    );
    await settings.save(prefs);
    if (_engineChoice == EngineChoice.cloud) {
      await widget.secretStore.write(secretKeyCloudApiKey, _apiKeyController.text);
    }
    widget.onFinished();
  }

  Widget _dots() {
    return Row(
      children: [
        for (var i = 0; i < _Step.values.length; i++)
          Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == _Step.values.length - 1 ? 0 : 10),
              decoration: BoxDecoration(
                color: i <= _step.index ? AppColors.fg : AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stepLabel(String text) =>
      Text(text, style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 1.5));

  Widget _bundleStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepLabel('STEP 1 OF 2'),
          const SizedBox(height: 16),
          Text('Point to your OKF bundle', style: appHeading()),
          const SizedBox(height: 16),
          Text(
            'Pick the folder on this device that holds your markdown knowledge files, or skip for now.',
            style: appBody(size: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          appSecondaryButton(label: 'Choose folder', onPressed: _pickBundleFolder),
          if (_okfBundlePath.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_okfBundlePath, style: appMono(size: 11.5, color: AppColors.muted)),
            const SizedBox(height: 6),
            Text(
              _bundleError ??
                  (_mdCount == null
                      ? 'Counting markdown files…'
                      : '$_mdCount markdown files found'),
              style: appMono(size: 11.5, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _llmStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      // The two choices are separated by their own detail panels, so a shared
      // RadioGroup ancestor is what binds them into one group now that
      // per-tile groupValue/onChanged are deprecated.
      child: RadioGroup<EngineChoice>(
        groupValue: _engineChoice,
        onChanged: (v) => setState(() => _engineChoice = v!),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _stepLabel('STEP 2 OF 2'),
            const SizedBox(height: 16),
            Text('Choose your LLM', style: appHeading()),
            const SizedBox(height: 14),
            RadioListTile<EngineChoice>(
              contentPadding: EdgeInsets.zero,
              title: Text('Cloud API', style: appBody(size: 14.5)),
              value: EngineChoice.cloud,
            ),
            if (_engineChoice == EngineChoice.cloud)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: Column(
                  children: [
                    appBorderedField(controller: _endpointController, hint: 'Endpoint URL'),
                    const SizedBox(height: 8),
                    appBorderedField(controller: _apiKeyController, hint: 'API key', obscure: true),
                    const SizedBox(height: 8),
                    appBorderedField(controller: _modelController, hint: 'Model name (optional)'),
                    const SizedBox(height: 8),
                    appBorderedField(
                      controller: _headersController,
                      hint: 'Extra headers (Name: value per line)',
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            RadioListTile<EngineChoice>(
              contentPadding: EdgeInsets.zero,
              title: Text('On-device (.gguf)', style: appBody(size: 14.5)),
              value: EngineChoice.onDevice,
            ),
            if (_engineChoice == EngineChoice.onDevice)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _onDeviceModelPath.isEmpty ? 'No model selected' : _onDeviceModelPath,
                        style: appMono(size: 11.5, color: AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 120,
                      child: appSecondaryButton(
                        label: 'Choose file',
                        onPressed: _pickOnDeviceModel,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0), child: _dots()),
            Expanded(
              child: Center(
                child: switch (_step) {
                  _Step.bundle => _bundleStep(),
                  _Step.llm => _llmStep(),
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: Column(
                children: [
                  appPrimaryButton(
                    label: _step == _Step.llm ? 'Finish setup' : 'Next',
                    onPressed: _next,
                  ),
                  if (_step == _Step.bundle)
                    TextButton(
                      onPressed: _skip,
                      child: Text('Skip', style: appBody(size: 13, color: AppColors.muted)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

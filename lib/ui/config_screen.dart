// lib/ui/config_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../engine/on_device_engine_registry.dart';
import '../agents/agent_registry.dart';
import '../agents/skill_state.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';
import '../settings/llm_library.dart';
import '../main.dart';
import '../theme/app_theme.dart';

class ConfigScreen extends StatefulWidget {
  final SecretStore secretStore;

  /// Indexing lives with whoever owns the index, not with this screen; the
  /// button here only asks for it. Null means there is nothing to ask.
  final VoidCallback? onReindex;
  final String? lastIndexedLabel;

  /// Opens the routing log. Null hides the row — there is nothing to show
  /// before a bundle has been opened.
  final VoidCallback? onOpenRouteLog;

  /// Cancels an indexing pass in flight. Null when nothing is running.
  final VoidCallback? onCancelIndex;

  /// 0..1 while indexing, null when idle. Drives the determinate bar the
  /// design specifies — an indeterminate spinner for a minutes-long job tells
  /// the user nothing about whether to wait.
  final double? indexFraction;

  const ConfigScreen({
    super.key,
    required this.secretStore,
    this.onReindex,
    this.lastIndexedLabel,
    this.onOpenRouteLog,
    this.onCancelIndex,
    this.indexFraction,
  });

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  /// The saved LLMs. This is the truth about which engine the app uses;
  /// [EngineSettings] is kept as its mirror by [applyActiveEntry].
  LlmLibrary _library = const LlmLibrary();
  String _okfBundlePath = '';
  String _embedModelPath = '';
  bool _loading = true;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  List<InstructionEntry> _skills = [];
  SkillState _skillState = SkillState();
  AgentRegistry _agents = const AgentRegistry();
  String _fileTools = '';
  String _agentLogicPath = '';
  List<InstructionEntry> _personas = [];
  AgentConfig _agentConfig = const AgentConfig();
  final _guardrailsController = TextEditingController();
  bool _modelBusy = false;
  int _modelBusyElapsedSeconds = 0;
  Timer? _modelBusyTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = await EngineSettings.load(prefs);
      final agentConfig = await AgentConfig.load(prefs);
      // Imports a pre-library setup on first run, so upgrading does not look
      // like the app forgot the LLM the user had configured.
      final library = await loadLlmLibrary(prefs, widget.secretStore);

      final docs = await getApplicationDocumentsDirectory();
      final skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
      final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
      final skills = await skillsLibrary.list();
      final personas = await personasLibrary.list();

      // Enabled-skill slugs are filtered against the live library, so a skill
      // deleted since the last launch stays deleted rather than reappearing.
      final skillState = await SkillState.load(prefs, knownSlugs: skills.map((s) => s.slug).toSet());
      final agents = await AgentRegistry.load(prefs);

      if (!mounted) return;
      setState(() {
        _library = library;
        _agentConfig = agentConfig;
        _guardrailsController.text = agentConfig.guardrails;
        _okfBundlePath = settings.okfBundlePath;
        _embedModelPath = settings.embedModelPath;
        _skillsLibrary = skillsLibrary;
        _personasLibrary = personasLibrary;
        _skills = skills;
        _personas = personas;
        _skillState = skillState;
        _agents = agents;
        _fileTools = settings.fileTools;
        _agentLogicPath = settings.agentLogicPath;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load settings: $e')));
      }
    }
  }

  /// Saves only what this button owns. LLM entries and the agent-framework
  /// switches persist at the moment they change, so Save can never be the
  /// difference between what the screen shows and what the app will do.
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final updatedAgentConfig = _agentConfig.copyWith(guardrails: _guardrailsController.text);
    await updatedAgentConfig.save(prefs);
    _agentConfig = updatedAgentConfig;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  /// Agent-framework switches persist on the spot rather than waiting for
  /// Save, so a flipped toggle is never a promise the app has not kept.
  Future<void> _saveAgentConfig(AgentConfig updated) async {
    setState(() => _agentConfig = updated);
    final prefs = await SharedPreferences.getInstance();
    await updated.save(prefs);
  }

  Future<void> _showEntryEditor({
    required InstructionLibrary library,
    required void Function(List<InstructionEntry>) onUpdated,
    InstructionEntry? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final descriptionController = TextEditingController(text: existing?.description ?? '');
    final contentController = TextEditingController(text: existing?.content ?? '');

    final saved = await showDialog<bool>(
      context: context,
      // The route owns the controllers: the fields are still live (and still
      // re-listening) while this dialog animates out.
      builder: (context) => DisposeWithRoute(
        controllers: [nameController, descriptionController, contentController],
        child: AlertDialog(
          backgroundColor: AppColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: AppColors.borderStrong),
          ),
          title: Text(existing == null ? 'Add' : 'Edit', style: appHeading(size: 16, weight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                appBorderedField(controller: nameController, hint: 'Name', enabled: existing == null),
                const SizedBox(height: 10),
                appBorderedField(controller: descriptionController, hint: 'Description'),
                const SizedBox(height: 10),
                appBorderedField(controller: contentController, hint: 'Content (Markdown)', maxLines: 5),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: appBody(size: 13, weight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Save', style: appBody(size: 13, weight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );

    // Safe to read after the await: the pop resumes this in the same turn,
    // long before the route (and the controllers with it) are disposed.
    if (saved != true) return;
    try {
      if (existing == null) {
        await library.add(
          name: nameController.text,
          description: descriptionController.text,
          content: contentController.text,
        );
      } else {
        await library.update(
          existing.slug,
          description: descriptionController.text,
          content: contentController.text,
        );
      }
      onUpdated(await library.list());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Widget _instructionSection({
    required String title,
    required InstructionLibrary? library,
    required List<InstructionEntry> entries,
    required void Function(List<InstructionEntry>) onUpdated,
    void Function(String slug)? onDeleted,
  }) {
    if (library == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: appHeading(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final entry in entries)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, style: appBody(size: 13.5, weight: FontWeight.w600)),
                      Text(entry.description, style: appBody(size: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.edit, size: 16, color: AppColors.fg),
                  onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated, existing: entry),
                ),
                IconButton(
                  icon: Icon(Icons.delete, size: 16, color: AppColors.fg),
                  onPressed: () async {
                    await library.delete(entry.slug);
                    onDeleted?.call(entry.slug);
                    onUpdated(await library.list());
                  },
                ),
              ],
            ),
          ),
        appSecondaryButton(
          label: '+ Add ${title.toLowerCase().substring(0, title.length - 1)}',
          onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated),
        ),
      ],
    );
  }

  String _newEntryId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Saves [library], re-mirrors it into [EngineSettings] so the chat screen
  /// resolves the same engine, and says out loud what just happened.
  Future<void> _commit(LlmLibrary library, String message) async {
    final prefs = await SharedPreferences.getInstance();
    await library.save(prefs);
    await applyActiveEntry(library, prefs, widget.secretStore);
    if (!mounted) return;
    setState(() => _library = library);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  Future<T?> _choiceDialog<T>({
    required String title,
    required String body,
    required Map<String, T> choices,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AppColors.borderStrong),
        ),
        title: Text(title, style: appHeading(size: 16, weight: FontWeight.w700)),
        content: Text(body, style: appBody(size: 13)),
        actions: [
          for (final choice in choices.entries)
            TextButton(
              onPressed: () => Navigator.of(context).pop(choice.value),
              child: Text(choice.key, style: appBody(size: 13, weight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  /// Appends an on-device model. Never replaces one: that was the bug.
  Future<void> _addOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path == null) return;
    if (_library.entries.any((e) => e.modelPath == path)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('That model file is already in the list.')));
      }
      return;
    }
    final entry = LlmEntry.onDevice(
      id: _newEntryId(),
      label: path.split('/').last,
      modelPath: path,
    );
    await _commit(_library.add(entry), 'Added "${entry.label}". Existing models were kept.');
  }

  Future<void> _addCloudModel() async {
    final label = TextEditingController();
    final endpoint = TextEditingController();
    final model = TextEditingController();
    final apiKey = TextEditingController();
    final headers = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      // The route owns the controllers: the fields are still live (and still
      // re-listening) while this dialog animates out.
      builder: (context) => DisposeWithRoute(
        controllers: [label, endpoint, model, apiKey, headers],
        child: AlertDialog(
          backgroundColor: AppColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: AppColors.borderStrong),
          ),
          title: Text('Add cloud LLM', style: appHeading(size: 16, weight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                appBorderedField(controller: label, hint: 'Name (optional)'),
                const SizedBox(height: 10),
                appBorderedField(controller: endpoint, hint: 'Endpoint URL'),
                const SizedBox(height: 10),
                appBorderedField(controller: apiKey, hint: 'API key', obscure: true),
                const SizedBox(height: 10),
                appBorderedField(controller: model, hint: 'Model name (optional)'),
                const SizedBox(height: 10),
                appBorderedField(
                  controller: headers,
                  hint: 'Extra headers (Name: value per line)',
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: appBody(size: 13, weight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Add', style: appBody(size: 13, weight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    // Safe to read after the await: the pop resumes this in the same turn,
    // long before the route (and the controllers with it) are disposed.
    final url = endpoint.text.trim();
    if (url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not added — a cloud LLM needs an endpoint URL.')));
      }
      return;
    }
    final name = model.text.trim();
    final entry = LlmEntry.cloud(
      id: _newEntryId(),
      label: label.text.trim().isNotEmpty
          ? label.text.trim()
          : (name.isNotEmpty ? name : 'Cloud API'),
      endpoint: url,
      model: name,
      headers: headers.text,
    );
    // The key goes to secure storage under this entry's own name; the entry
    // itself has nowhere to hold a secret, so nothing key-shaped can reach
    // shared_preferences.
    await widget.secretStore.write(entry.secretKey!, apiKey.text);
    await _commit(
      _library.add(entry),
      'Added "${entry.label}". Its API key is in secure storage, not in settings.',
    );
  }

  /// Makes [entry] the active LLM.
  ///
  /// Any model currently resident is unloaded first: only one model stays in
  /// memory at a time, because two loaded models on a phone invites the OS to
  /// kill the app.
  Future<void> _activate(LlmEntry entry) async {
    setState(() => _modelBusy = true);
    try {
      final loadedPath = OnDeviceEngineRegistry.instance.loadedModelPath;
      final unloaded = loadedPath != null && loadedPath != entry.modelPath;
      if (unloaded) await OnDeviceEngineRegistry.instance.unload();
      await _commit(
        _library.setActive(entry.id),
        unloaded
            ? 'Now using "${entry.label}". The previously loaded model was unloaded first — '
                'only one model stays in memory.'
            : 'Now using "${entry.label}".',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not switch model: $e')));
      }
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  /// Removing an entry always states which of the two things happened: the
  /// file was deleted, or it is still sitting on the device. Not knowing which
  /// is the complaint this whole section exists to fix.
  Future<void> _confirmRemove(LlmEntry entry) async {
    if (entry.kind == LlmKind.cloud) {
      final confirmed = await _choiceDialog<bool>(
        title: 'Remove "${entry.label}"?',
        body: 'This removes the cloud LLM from your library and clears its API key from this '
            "device's secure storage. Nothing is changed on the provider's side.",
        choices: {'Cancel': false, 'Remove': true},
      );
      if (confirmed != true) return;
      await widget.secretStore.write(entry.secretKey!, '');
      await _commit(
        _library.remove(entry.id),
        'Removed "${entry.label}" and cleared its stored API key.',
      );
      return;
    }

    final path = entry.modelPath ?? '';
    final choice = await _choiceDialog<String>(
      title: 'Remove "${entry.label}"?',
      body: 'The model file is at:\n$path\n\n'
          'Remove from list — the file stays on your device, keeps using its storage, and you '
          'can add it again later.\n\n'
          'Delete file too — the file is erased from your device permanently.',
      choices: {'Cancel': 'cancel', 'Remove from list': 'keep', 'Delete file too': 'delete'},
    );
    if (choice == null || choice == 'cancel') return;

    setState(() => _modelBusy = true);
    try {
      if (OnDeviceEngineRegistry.instance.isLoadedFor(path)) {
        await OnDeviceEngineRegistry.instance.unload();
      }
      var outcome =
          'Removed "${entry.label}" from the list. The file is still on your device at $path.';
      if (choice == 'delete') {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          outcome = 'Removed "${entry.label}" and deleted the file from your device: $path';
        } else {
          outcome = 'Removed "${entry.label}". No file was deleted — nothing exists at $path.';
        }
      }
      await _commit(_library.remove(entry.id), outcome);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Nothing was removed — deleting the file failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _loadModel(String path) async {
    if (path.isEmpty) return;

    // Fail fast on an obviously bad file instead of waiting out the full
    // native load timeout for something that can never succeed.
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Model file no longer exists at this path.')));
      }
      return;
    }
    final size = await file.length();
    if (size < 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Model file looks truncated/corrupt (${size}B) — re-download or re-pick it.')));
      }
      return;
    }

    setState(() => _modelBusy = true);
    _modelBusyElapsedSeconds = 0;
    _modelBusyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _modelBusyElapsedSeconds++);
    });
    try {
      await OnDeviceEngineRegistry.instance.forPath(path).load();
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Model load timed out after ${_modelBusyElapsedSeconds}s — likely stuck, not just slow. Try a smaller model or restart the app.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load model: $e')));
      }
    } finally {
      _modelBusyTimer?.cancel();
      _modelBusyTimer = null;
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _offloadModel() async {
    setState(() => _modelBusy = true);
    try {
      await OnDeviceEngineRegistry.instance.unload();
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Widget _entryCard(LlmEntry entry) {
    final isActive = entry.id == _library.activeEntryId;
    final isOnDevice = entry.kind == LlmKind.onDevice;
    final path = entry.modelPath ?? '';
    final loaded = isOnDevice && OnDeviceEngineRegistry.instance.isLoadedFor(path);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fg, width: isActive ? 3 : 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.label,
                  style: appBody(size: 13.5, weight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isActive) Text('ACTIVE', style: appMono(size: 10).copyWith(letterSpacing: 1.2)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            isOnDevice ? 'On-device (.gguf) · $path' : 'Cloud · ${entry.endpoint}',
            style: appMono(size: 11, color: AppColors.muted),
            overflow: TextOverflow.ellipsis,
          ),
          if (isOnDevice) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: loaded ? Colors.greenAccent : AppColors.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  loaded ? 'Loaded in memory' : 'Not loaded',
                  style: appMono(size: 11, color: loaded ? Colors.greenAccent : AppColors.muted),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (!isActive) ...[
                Expanded(
                  child: appSecondaryButton(
                    label: 'Use',
                    onPressed: _modelBusy ? null : () => _activate(entry),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: appSecondaryButton(
                  label: 'Remove',
                  onPressed: _modelBusy ? null : () => _confirmRemove(entry),
                ),
              ),
            ],
          ),
          if (isActive && isOnDevice) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: appSecondaryButton(
                    label: loaded
                        ? 'Loaded'
                        : (_modelBusy ? 'Loading… ${_modelBusyElapsedSeconds}s' : 'Load'),
                    onPressed: (loaded || _modelBusy) ? null : () => _loadModel(path),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: appSecondaryButton(
                    label: 'Offload',
                    onPressed: (!loaded || _modelBusy) ? null : _offloadModel,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _modelsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_library.entries.isEmpty)
          Text(
            'No LLMs saved yet. Add an on-device .gguf file or a cloud API below — '
            'adding one never replaces another.',
            style: appBody(size: 12.5, color: AppColors.muted),
          )
        else ...[
          for (final entry in _library.entries) _entryCard(entry),
          if (_library.activeEntry == null)
            Text(
              'None selected — pick one with "Use", or the chat has no engine to talk to.',
              style: appBody(size: 12.5, color: AppColors.muted),
            ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: appSecondaryButton(
                label: '+ On-device',
                onPressed: _modelBusy ? null : _addOnDeviceModel,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: appSecondaryButton(
                label: '+ Cloud API',
                onPressed: _modelBusy ? null : _addCloudModel,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickOkfBundle() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    // Re-read rather than reusing a settings object captured at load: the
    // active-entry mirror writes to the same store between then and now.
    final prefs = await SharedPreferences.getInstance();
    await (await EngineSettings.load(prefs)).copyWith(okfBundlePath: path).save(prefs);
    if (mounted) setState(() => _okfBundlePath = path);
  }

  Future<void> _pickEmbedModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['gguf']);
    final path = result?.files.single.path;
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await (await EngineSettings.load(prefs)).copyWith(embedModelPath: path).save(prefs);
    if (mounted) setState(() => _embedModelPath = path);
  }

  Widget _pathRow({required String value, required String empty, required String buttonLabel, required VoidCallback onPressed}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            value.isEmpty ? empty : value,
            style: appMono(size: 11.5, color: AppColors.muted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 140, child: appSecondaryButton(label: buttonLabel, onPressed: onPressed)),
      ],
    );
  }

  Widget _toggleRow({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: appBody(size: 13.5, weight: FontWeight.w600)),
                Text(description, style: appBody(size: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.bg,
            activeTrackColor: AppColors.fg,
            inactiveThumbColor: AppColors.fg,
            inactiveTrackColor: AppColors.bg,
          ),
        ],
      ),
    );
  }

  /// A row with a filled dot when on — the design's toggle for both skills
  /// and file tools. A Switch would be louder than everything around it.
  Widget _dotRow({required String label, required bool enabled, VoidCallback? onTap, String? subtitle}) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: appBody(size: 13, color: onTap == null ? AppColors.faint : AppColors.fg)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle, style: appMono(size: 10.5, color: AppColors.faint)),
              ],
            ]),
          ),
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? AppColors.accent : Colors.transparent,
              border: Border.all(color: enabled ? AppColors.accent : AppColors.borderStrong),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _toggleSkill(String slug) async {
    final updated = _skillState.toggle(slug);
    setState(() => _skillState = updated);
    await updated.save(await SharedPreferences.getInstance());
  }

  Future<void> _toggleFileTool(String extension) async {
    final set = Set<String>.from(_fileTools
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty));
    set.contains(extension) ? set.remove(extension) : set.add(extension);
    final value = (set.toList()..sort()).join(',');

    setState(() => _fileTools = value);
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    await settings.copyWith(fileTools: value).save(prefs);
  }

  Future<void> _pickAgentLogic() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['md']);
    final path = result?.files.single.path;
    if (path == null) return;

    setState(() => _agentLogicPath = path);
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    await settings.copyWith(agentLogicPath: path).save(prefs);
  }

  Future<void> _addAgent() async {
    final nameController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWithRoute(
        controllers: [nameController],
        child: AlertDialog(
          backgroundColor: AppColors.bg,
          title: Text('New agent', style: appHeading(size: 15)),
          content: appBorderedField(controller: nameController, hint: 'Agent name'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: appBody(size: 12, color: AppColors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Create', style: appBody(size: 12, color: AppColors.accent)),
            ),
          ],
        ),
      ),
    );
    if (!(saved ?? false) || nameController.text.trim().isEmpty) return;

    // A new agent inherits whichever model is active — the design's cards show
    // a model per agent, and an agent with no model could not answer at all.
    final updated = _agents.add(AgentEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: nameController.text.trim(),
      modelId: _library.activeEntryId ?? '',
    ));
    setState(() => _agents = updated);
    await updated.save(await SharedPreferences.getInstance());
  }

  /// Swaps the palette and persists it.
  ///
  /// The rebuild has to come from above every screen — `AppColors` is a set of
  /// globals, so nothing re-reads it on its own. `ThemeScope` at the app root
  /// is what actually repaints.
  Future<void> _setTheme(bool dark) async {
    applyThemeMode(dark);
    if (mounted) ThemeScope.of(context)?.onThemeChanged();
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    await settings.copyWith(themeMode: dark ? 'dark' : 'light').save(prefs);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.fg)));
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('Agent configuration', style: appHeading(size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          Divider(color: AppColors.fg, thickness: 2, height: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              children: [
                Text('LLM library', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'Every LLM you have saved. The one marked ACTIVE is what the chat talks to. '
                  'Only one on-device model is ever held in memory at a time.',
                  style: appBody(size: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 10),
                _modelsSection(),
                const SizedBox(height: 22),

                Text('Agent framework', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 10),
                _toggleRow(
                  title: 'LangChain',
                  description: 'Real, and in this app: the langchain 0.8.1 Dart package, with an '
                      'adapter (lib/engine/langchain_chat_model.dart) that wraps our cloud and '
                      'on-device engines.\n'
                      'Not wired into chat yet — turning this on saves the preference and does '
                      'not change how replies are generated.',
                  value: _agentConfig.langchainEnabled,
                  onChanged: (v) => _saveAgentConfig(_agentConfig.copyWith(langchainEnabled: v)),
                ),
                _toggleRow(
                  title: 'Graph orchestration',
                  description: "This app's own graph engine (lib/agent/graph_engine.dart): nodes, "
                      'edges, cycles and shared state, running on the device.\n'
                      'This is NOT LangGraph. No Dart LangGraph engine exists — the only package '
                      'is an HTTP client for a hosted LangGraph server, which this app does not run.',
                  value: _agentConfig.graphOrchestrationEnabled,
                  onChanged: (v) =>
                      _saveAgentConfig(_agentConfig.copyWith(graphOrchestrationEnabled: v)),
                ),
                if (_agentConfig.graphOrchestrationEnabled) ...[
                  const SizedBox(height: 4),
                  appStepper(
                    label: 'Max reasoning loops',
                    value: _agentConfig.maxSteps,
                    min: AgentConfig.stepsMin,
                    max: AgentConfig.stepsMax,
                    onChanged: (v) => _saveAgentConfig(_agentConfig.copyWith(maxSteps: v)),
                  ),
                  Text(
                    'A hard stop, not a hint: the graph run ends at this many steps. Higher costs '
                    'proportionally more time and, on a cloud engine, more tokens.',
                    style: appBody(size: 11.5, color: AppColors.muted),
                  ),
                ],
                const SizedBox(height: 22),

                Text('Knowledge base', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'The folder of markdown this app answers from, and the embedding model used to '
                  'index it. Changing either needs a reindex before answers reflect it.',
                  style: appBody(size: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 10),
                _pathRow(
                  value: _okfBundlePath,
                  empty: 'No OKF bundle folder chosen',
                  buttonLabel: 'Choose folder',
                  onPressed: _pickOkfBundle,
                ),
                const SizedBox(height: 8),
                _pathRow(
                  value: _embedModelPath,
                  empty: 'No embedding model chosen',
                  buttonLabel: 'Choose .gguf',
                  onPressed: _pickEmbedModel,
                ),
                const SizedBox(height: 10),
                Text(
                  'Last indexed: ${widget.lastIndexedLabel ?? 'never'}',
                  style: appMono(size: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 8),
                if (widget.indexFraction != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: widget.indexFraction,
                      minHeight: 6,
                      backgroundColor: AppColors.border,
                      valueColor: AlwaysStoppedAnimation(AppColors.accent),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(widget.lastIndexedLabel ?? '',
                        style: appMono(size: 11, color: AppColors.faint)),
                    GestureDetector(
                      onTap: widget.onCancelIndex,
                      child: Text('Cancel',
                          style: appBody(size: 11, color: AppColors.faint)),
                    ),
                  ]),
                ] else
                  appSecondaryButton(label: 'Reindex now', onPressed: widget.onReindex),
                const SizedBox(height: 14),
                Text('FILE TOOLS', style: appSectionLabel()),
                const SizedBox(height: 4),
                Text(
                  'File types the agent may read and cite alongside markdown. Each one costs '
                  'extraction time on every reindex.',
                  style: appBody(size: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 10),
                for (final tool in _kFileTools)
                  _dotRow(
                    label: tool.label,
                    subtitle: tool.supported ? null : 'not supported offline',
                    enabled: _fileTools
                        .split(',')
                        .map((e) => e.trim())
                        .contains(tool.extension),
                    // An unsupported format is shown but not togglable: a
                    // switch that indexes nothing is worse than a visible gap,
                    // because the user cannot tell it failed.
                    onTap: tool.supported ? () => _toggleFileTool(tool.extension) : null,
                  ),
                const SizedBox(height: 14),

                Text('CUSTOM AGENTS', style: appSectionLabel()),
                const SizedBox(height: 10),
                for (final agent in _agents.agents)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(agent.name, style: appBody(size: 13)),
                          const SizedBox(height: 3),
                          Text(
                            _library.entries
                                    .where((e) => e.id == agent.modelId)
                                    .map((e) => e.label)
                                    .firstOrNull ??
                                'no model',
                            style: appMono(size: 11, color: AppColors.faint),
                          ),
                        ]),
                      ),
                      GestureDetector(
                        onTap: () async {
                          final updated = _agents.remove(agent.id);
                          setState(() => _agents = updated);
                          await updated.save(await SharedPreferences.getInstance());
                        },
                        child: Icon(Icons.close, size: 16, color: AppColors.faint),
                      ),
                    ]),
                  ),
                GestureDetector(
                  onTap: _addAgent,
                  child: Text('+ New agent',
                      style: appBody(size: 12, weight: FontWeight.w600, color: AppColors.accent)),
                ),
                const SizedBox(height: 22),

                Text('AGENT LOGIC', style: appSectionLabel()),
                const SizedBox(height: 8),
                _pathRow(
                  value: _agentLogicPath,
                  empty: 'Using the built-in system prompt',
                  buttonLabel: 'Choose .md',
                  onPressed: _pickAgentLogic,
                ),
                const SizedBox(height: 6),
                Text(
                  'Defines persona, routing rules, and tool permissions for the active agent.',
                  style: appMono(size: 11, color: AppColors.faint),
                ),
                const SizedBox(height: 22),

                Text('APPEARANCE', style: appSectionLabel()),
                const SizedBox(height: 8),
                Row(children: [
                  for (final entry in const [('Dark', true), ('Light', false)])
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _setTheme(entry.$2),
                        child: Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: appIsDark == entry.$2 ? AppColors.accent : Colors.transparent,
                            border: Border.all(
                                color: appIsDark == entry.$2
                                    ? AppColors.accent
                                    : AppColors.borderStrong),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Center(
                            child: Text(
                              entry.$1,
                              style: appBody(
                                size: 12,
                                weight: FontWeight.w600,
                                color: appIsDark == entry.$2
                                    ? AppColors.onAccent
                                    : AppColors.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 22),

                Text('DIAGNOSTICS', style: appSectionLabel()),
                const SizedBox(height: 6),
                Text(
                  'Every routing decision is recorded on device. After a couple of hundred real '
                  'queries the fallback and override rates say which heuristics to keep.',
                  style: appBody(size: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 8),
                appSecondaryButton(label: 'Routing log', onPressed: widget.onOpenRouteLog),
                const SizedBox(height: 22),

                if (_skills.isNotEmpty) ...[
                  Text('ENABLED SKILLS', style: appSectionLabel()),
                  const SizedBox(height: 8),
                  for (final skill in _skills)
                    _dotRow(
                      label: skill.name,
                      enabled: _skillState.isEnabled(skill.slug),
                      onTap: () => _toggleSkill(skill.slug),
                    ),
                  const SizedBox(height: 14),
                ],
                _instructionSection(
                  title: 'Skills',
                  library: _skillsLibrary,
                  entries: _skills,
                  onUpdated: (updated) => setState(() => _skills = updated),
                ),
                const SizedBox(height: 22),

                _instructionSection(
                  title: 'Personas',
                  library: _personasLibrary,
                  entries: _personas,
                  onUpdated: (updated) => setState(() => _personas = updated),
                  onDeleted: (slug) async {
                    if (_agentConfig.defaultPersonaSlug == slug) {
                      setState(() => _agentConfig = _agentConfig.copyWith(clearPersona: true));
                      final prefs = await SharedPreferences.getInstance();
                      await _agentConfig.save(prefs);
                    }
                  },
                ),
                if (_personasLibrary != null) ...[
                  const SizedBox(height: 8),
                  Text('Default persona', style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 0.6)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: _agentConfig.defaultPersonaSlug,
                        isExpanded: true,
                        dropdownColor: AppColors.bg,
                        style: appBody(size: 13),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('None')),
                          for (final p in _personas) DropdownMenuItem<String?>(value: p.slug, child: Text(p.name)),
                        ],
                        onChanged: (slug) => setState(() {
                          _agentConfig = _agentConfig.copyWith(defaultPersonaSlug: slug, clearPersona: slug == null);
                        }),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 22),

                Text('Guardrails', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                appBorderedField(
                  controller: _guardrailsController,
                  hint: 'One rule per line, always applied',
                  maxLines: 4,
                ),
                const SizedBox(height: 22),

                appPrimaryButton(label: 'Save', onPressed: _save),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _guardrailsController.dispose();
    _modelBusyTimer?.cancel();
    super.dispose();
  }
}

/// The file types the design's FILE TOOLS section lists.
///
/// [supported] is honest about what the extractors can actually do offline:
/// PDF needs a parser dependency the app does not carry, and image OCR needs
/// ML Kit plus a platform channel. Showing them greyed is better than hiding
/// them — the user learns the format exists and is not available, rather than
/// wondering why their PDFs never appear in an answer.
class _FileTool {
  final String label;
  final String extension;
  final bool supported;
  const _FileTool(this.label, this.extension, {this.supported = true});
}

const _kFileTools = [
  _FileTool('Text', 'txt'),
  _FileTool('CSV', 'csv'),
  _FileTool('Word', 'docx'),
  _FileTool('Excel', 'xlsx'),
  _FileTool('PowerPoint', 'pptx'),
  _FileTool('PDF', 'pdf', supported: false),
  _FileTool('Image', 'png', supported: false),
];

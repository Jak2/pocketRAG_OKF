import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine_factory.dart';
import '../engine/generation_event.dart';
import '../chat/transcript_export.dart';
import '../engine/llm_engine.dart';
import '../engine/on_device_llama_engine.dart';
import '../retrieval/knowledge_service.dart';
import '../retrieval/retrieval_result.dart';
import '../retrieval/retrieval_service.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';
import 'source_screen.dart';

/// One entry in the transcript.
class ChatTurn {
  final bool fromUser;
  String text;

  /// Present only on assistant turns produced by a retrieval run — this is
  /// what the mode chip and the sources list render from.
  final RetrievalOutcome? outcome;

  /// True while tokens are still arriving.
  bool streaming;

  /// The question this answer came from, kept so "retry as X" can re-run it
  /// without the user retyping.
  final String? question;

  ChatTurn({
    required this.fromUser,
    required this.text,
    this.outcome,
    this.streaming = false,
    this.question,
  });
}

class ChatScreen extends StatefulWidget {
  final SecretStore secretStore;
  final KnowledgeService knowledge;
  final VoidCallback? onOpenConfig;
  final VoidCallback? onOpenMemory;

  /// Bumped by [RootScreen] whenever the user leaves Config, so a changed
  /// bundle or embedding-model path is picked up without an app restart. The
  /// tabs live in an IndexedStack, so this screen is never rebuilt from
  /// scratch and has no other way to notice.
  final int configRevision;

  const ChatScreen({
    super.key,
    required this.secretStore,
    required this.knowledge,
    this.onOpenConfig,
    this.onOpenMemory,
    this.configRevision = 0,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <ChatTurn>[];

  RetrievalMode _mode = RetrievalMode.auto;
  EngineSettings _settings = const EngineSettings();
  bool _busy = false;
  String _status = '';

  /// Answers since the last memory extraction. Extraction costs a whole LLM
  /// call, so it runs periodically rather than every turn.
  int _turnsSinceExtraction = 0;
  static const _extractEvery = 6;

  /// Answers whose routing detail is open. Held here rather than on the turn
  /// so a re-run replaces the turn without stranding its expanded state.
  final _expandedTurns = <ChatTurn>{};

  /// Session identity for anything written to the memory store.
  final _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configRevision != widget.configRevision) _loadSettings();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';
    if (!mounted) return;
    setState(() {
      _settings = settings.copyWith(cloudApiKey: apiKey);
      _mode = RetrievalMode.values.firstWhere(
        (m) => m.name == settings.retrievalMode,
        orElse: () => RetrievalMode.auto,
      );
    });

    // Picking a different folder or embedding model in Config has to take
    // effect without restarting the app, but re-reading the bundle on every
    // rebuild would be gratuitous.
    // The enabled file-tool set is part of the open configuration: turning on
    // PDF changes what the corpus contains, so it has to force a reopen just
    // as a new folder does.
    if (widget.knowledge.isOpenFor(
      bundlePath: settings.okfBundlePath,
      embedModelPath: settings.embedModelPath,
      fileTools: settings.fileToolSet,
      agentLogicPath: settings.agentLogicPath,
    )) {
      return;
    }

    await widget.knowledge.open(
      bundlePath: settings.okfBundlePath,
      embedModelPath: settings.embedModelPath,
      fileTools: settings.fileToolSet,
      agentLogicPath: settings.agentLogicPath,
    );
    if (mounted) setState(() {});
  }

  Future<void> _setMode(RetrievalMode mode) async {
    setState(() => _mode = mode);
    final prefs = await SharedPreferences.getInstance();
    await _settings.copyWith(retrievalMode: mode.name).save(prefs);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? overrideText, RetrievalMode? overrideMode]) async {
    final question = (overrideText ?? _input.text).trim();
    if (question.isEmpty || _busy) return;

    final engine = buildEngine(_settings);
    if (engine == null) {
      setState(() => _turns.add(ChatTurn(
            fromUser: false,
            text: 'No LLM configured. Open Config and set a cloud endpoint or an on-device model.',
          )));
      return;
    }

    setState(() {
      if (overrideText == null) _input.clear();
      _turns.add(ChatTurn(fromUser: true, text: question));
      _busy = true;
      _status = 'retrieving…';
    });
    _scrollToEnd();

    // History excludes the question just added, which is passed separately.
    final history = _turns
        .take(_turns.length - 1)
        .map((t) => '${t.fromUser ? 'User' : 'Assistant'}: ${t.text}')
        .toList();

    final prepared = await widget.knowledge.prepare(
      question: question,
      requested: overrideMode ?? _mode,
      history: history,
      contextTokens: _settings.choice == EngineChoice.onDevice ? kOnDeviceContextTokens : 8192,
      // Only the router's third stage uses the model, and only when the
      // heuristics are silent.
      classifierEngine: (overrideMode ?? _mode) == RetrievalMode.auto ? engine : null,
    );

    await widget.knowledge.routeLog?.append(
      prepared.outcome.toLogEntry(question, userOverride: overrideMode?.name),
    );

    final answer = ChatTurn(
      fromUser: false,
      text: '',
      outcome: prepared.outcome,
      streaming: true,
      question: question,
    );
    setState(() {
      _turns.add(answer);
      _status = 'generating…';
    });

    await for (final event in engine.generateStream(prepared.prompt)) {
      if (!mounted) return;
      switch (event) {
        case GenerationStatus(:final stage):
          setState(() => _status = stage);
        case GenerationToken(:final text):
          setState(() => answer.text += text);
          _scrollToEnd();
        case GenerationDone(:final fullText):
          setState(() {
            answer.text = fullText;
            answer.streaming = false;
          });
        case GenerationError(:final message):
          setState(() {
            answer.text = 'Generation failed: $message';
            answer.streaming = false;
          });
      }
    }

    if (mounted) {
      setState(() {
        answer.streaming = false;
        _busy = false;
        _status = '';
      });
      _scrollToEnd();
    }

    await _maybeExtractMemories(engine);
  }

  /// Harvests durable facts from the conversation every [_extractEvery] turns.
  ///
  /// Deliberately not on dispose: a phone kills the process without warning, so
  /// anything deferred to teardown is a fact the app quietly forgets. Failures
  /// are silent by design — a missed extraction is invisible to the user and
  /// must never surface as an error on a turn that otherwise succeeded.
  Future<void> _maybeExtractMemories(LlmEngine engine) async {
    if (++_turnsSinceExtraction < _extractEvery) return;
    _turnsSinceExtraction = 0;
    try {
      await widget.knowledge.extractMemories(
        engine: engine,
        conversation:
            _turns.map((t) => '${t.fromUser ? 'User' : 'Assistant'}: ${t.text}').toList(),
        sessionId: _sessionId,
      );
    } catch (_) {
      // Memory is an enhancement; a failed extraction never breaks the chat.
    }
  }

  /// "Wrong mode, retry as X" — re-runs the same question in the other mode
  /// and records the override. The single highest-value control here: it is
  /// what turns a bad routing decision into tuning data instead of a dead end.
  Future<void> _retryAs(ChatTurn turn, RetrievalMode mode) async {
    if (turn.question == null) return;
    setState(() => _turns.removeRange(_turns.indexOf(turn) - 1, _turns.length));
    await _send(turn.question, mode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: _turns.isEmpty
                  ? _emptyState()
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: _turns.length,
                      itemBuilder: (_, i) => _turnView(_turns[i]),
                    ),
            ),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(children: [
                  const SizedBox(
                      width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 8),
                  Text(_status, style: appMono(size: 11, color: AppColors.muted)),
                ]),
              ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final knowledge = widget.knowledge;
    final subtitle = knowledge.isReady
        ? '${knowledge.conceptCount} concepts · ${knowledge.chunkCount} chunks'
            '${knowledge.hasEmbeddings ? '' : ' · keyword only'}'
            '${knowledge.indexStale ? ' · index stale' : ''}'
            '${knowledge.skippedFiles.isEmpty ? '' : ' · ${knowledge.skippedFiles.length} unreadable'}'
        : 'No bundle — pick a folder in Config';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pocket RAG', style: appHeading(size: 17, weight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(subtitle, style: appMono(size: 11, color: AppColors.faint)),
          ]),
        ),
        IconButton(
          onPressed: _turns.isEmpty ? null : _export,
          icon: Icon(Icons.ios_share, size: 18, color: AppColors.muted),
        ),
        IconButton(
          onPressed: widget.onOpenMemory,
          icon: Icon(Icons.psychology_outlined, size: 19, color: AppColors.muted),
        ),
        IconButton(
          onPressed: widget.onOpenConfig,
          icon: Icon(Icons.tune, size: 19, color: AppColors.muted),
        ),
      ]),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Ask your knowledge base', style: appHeading(size: 18)),
            const SizedBox(height: 8),
            Text(
              'RAG searches fragments. OKF walks whole linked documents. '
              'Auto picks one and tells you which.',
              textAlign: TextAlign.center,
              style: appBody(size: 13, color: AppColors.muted),
            ),
          ]),
        ),
      );

  Widget _turnView(ChatTurn turn) {
    if (turn.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          margin: const EdgeInsets.only(bottom: 22, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(turn.text, style: appBody(size: 14.5, height: 1.5)),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (turn.outcome != null) _modeChip(turn),
        const SizedBox(height: 6),
        SelectableText(
          turn.text.isEmpty && turn.streaming ? '…' : turn.text,
          style: appBody(size: 14.5, height: 1.65),
        ),
        if (turn.outcome != null && !turn.streaming) _sources(turn.outcome!),
      ]),
    );
  }

  /// Shows what actually ran, and opens onto why.
  ///
  /// When Auto fires this is the only way the user can tell which strategy
  /// answered. An unlabelled auto-router is untunable and untrustworthy, so
  /// the chip is always present and the detail is always one tap away.
  Widget _modeChip(ChatTurn turn) {
    final outcome = turn.outcome!;
    final decision = outcome.decision;
    final label = decision.reason == 'manual'
        ? outcome.result.mode.label
        : 'auto → ${outcome.result.mode.label}';
    final expanded = _expandedTurns.contains(turn);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(100),
        onTap: () => setState(() {
          expanded ? _expandedTurns.remove(turn) : _expandedTurns.add(turn);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.borderStrong),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: appMono(size: 11, color: AppColors.accent, weight: FontWeight.w600)),
            if (outcome.fellBack) ...[
              const SizedBox(width: 6),
              Text('fallback', style: appMono(size: 11, color: AppColors.faint)),
            ],
          ]),
        ),
      ),
      if (expanded) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _detail('reason', decision.reason),
            _detail('confidence',
                '${(decision.confidence * 100).round()}%  ·  latency: ${decision.latencyMs}ms'),
            _detail('items',
                '${outcome.result.items.length}  ·  tokens: ${outcome.result.totalTokens}'),
            if (outcome.result.seeds.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('seeds:', style: appMono(size: 11.5, color: AppColors.muted, height: 1.6)),
              for (final seed in outcome.result.seeds)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text('· $seed',
                      style: appMono(size: 11.5, color: AppColors.fg, height: 1.6)),
                ),
            ],
            const SizedBox(height: 10),
            // The highest-value control in the app: it turns a bad routing
            // decision into recorded evidence instead of a dead end.
            InkWell(
              borderRadius: BorderRadius.circular(100),
              onTap: _busy
                  ? null
                  : () => _retryAs(
                        turn,
                        outcome.result.mode == RetrievalMode.graph
                            ? RetrievalMode.vector
                            : RetrievalMode.graph,
                      ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  'Wrong mode — retry as '
                  '${outcome.result.mode == RetrievalMode.graph ? 'RAG' : 'OKF'}',
                  style: appBody(
                      size: 12, color: AppColors.accentText, weight: FontWeight.w600),
                ),
              ),
            ),
          ]),
        ),
      ],
    ]);
  }

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: RichText(
          text: TextSpan(children: [
            TextSpan(
                text: '$label: ',
                style: appMono(size: 11.5, color: AppColors.muted, height: 1.6)),
            TextSpan(
                text: value, style: appMono(size: 11.5, color: AppColors.fg, height: 1.6)),
          ]),
        ),
      );

  Widget _sources(RetrievalOutcome outcome) {
    if (outcome.result.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('No sources retrieved', style: appMono(size: 10, color: AppColors.muted)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final source in outcome.result.sources.toSet())
            InkWell(
              onTap: () => _openSource(source),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(source, style: appMono(size: 11, color: AppColors.muted)),
              ),
            ),
        ],
      ),
    );
  }

  /// Saves the session as markdown.
  ///
  /// Markdown, not PDF: this app reads markdown, so an export written into the
  /// knowledge folder becomes a searchable source on the next reindex. A
  /// binary format would need a dependency and produce a file the app itself
  /// could not read back.
  Future<void> _export() async {
    final questionsOnly = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg,
        title: Text('Save conversation', style: appHeading(size: 15)),
        content: Text(
          'Save the whole transcript, or only the questions you asked?',
          style: appBody(size: 13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Full transcript', style: appBody(size: 12, color: AppColors.fg)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Questions only', style: appBody(size: 12, color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (questionsOnly == null || !mounted) return;

    final now = DateTime.now();
    final firstQuestion = _turns.where((t) => t.fromUser).map((t) => t.text).firstOrNull;
    final markdown = renderTranscript(
      turns: _turns
          .map((t) => TranscriptTurn(
                fromUser: t.fromUser,
                text: t.text,
                mode: t.outcome?.result.mode.label,
                sources: t.outcome?.result.sources.toSet().toList() ?? const [],
              ))
          .toList(),
      at: now,
      title: firstQuestion ?? 'Conversation',
      questionsOnly: questionsOnly,
    );

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save as markdown',
      fileName: transcriptFileName(now, questionsOnly: questionsOnly),
      // The bytes are passed too: on Android saveFile writes them itself,
      // because the app cannot write to the returned SAF path directly.
      bytes: utf8.encode(markdown),
    );
    if (path == null || !mounted) return;

    // On the platforms where saveFile only returns a path, the write is ours.
    try {
      final file = File(path);
      if (!await file.exists()) await file.writeAsString(markdown);
    } catch (_) {
      // saveFile already wrote it, or the path is a SAF URI we cannot open.
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $path', style: appBody(size: 12))),
      );
    }
  }

  /// Opens the raw markdown behind a citation. Memory facts have no file to
  /// show, and a concept can be missing if the bundle changed under a stale
  /// answer — both are no-ops rather than errors.
  void _openSource(String source) {
    if (source.startsWith('memory:')) return;
    final concept = widget.knowledge.corpus?.bundle.byPath(source);
    if (concept == null) return;

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourceScreen(
        concept: concept,
        onFollowLink: (relpath) {
          Navigator.of(context).pop();
          _openSource(relpath);
        },
      ),
    ));
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(children: [
        _modeSwitch(),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border.all(color: AppColors.borderStrong),
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _input,
                maxLines: 4,
                minLines: 1,
                style: appBody(size: 14, height: 1.4),
                decoration: InputDecoration(
                  hintText: 'Ask your knowledge base…',
                  hintStyle: appBody(size: 14, color: AppColors.faint),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: _busy ? null : () => _send(),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _busy ? AppColors.surfaceMuted : AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.arrow_upward,
                  size: 16, color: _busy ? AppColors.faint : AppColors.onAccent),
            ),
          ),
        ]),
      ]),
    );
  }

  /// Three-position control. The manual positions are obeyed literally; Auto
  /// routes and always reports what it picked.
  Widget _modeSwitch() {
    const modes = [RetrievalMode.vector, RetrievalMode.graph, RetrievalMode.auto];
    return Row(
      children: [
        for (final mode in modes)
          Expanded(
            child: GestureDetector(
              onTap: () => _setMode(mode),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _mode == mode ? AppColors.accent : Colors.transparent,
                  border: Border.all(
                      color: _mode == mode ? AppColors.accent : AppColors.borderStrong),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Center(
                  child: Text(
                    mode.label,
                    style: appMono(
                      size: 12.5,
                      weight: FontWeight.w600,
                      color: _mode == mode ? AppColors.onAccent : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

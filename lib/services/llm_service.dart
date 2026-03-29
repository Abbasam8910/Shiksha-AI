import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'model_download_service.dart';
import 'device_config_service.dart';
import '../utils/memory_utils.dart';


class LLMService {
  final ModelDownloadService _downloadService;
  late ModelConfig _config;

  // System prompt is now dynamic - loaded from _config.systemPrompt

  LlamaParent? _llamaParent;
  StreamSubscription? _streamSubscription;
  bool _isInitialized = false;
  bool _isLoading = false;

  ChatHistory? _chatHistory;
  ChatMLFormat? _chatFormat;

  StreamController<String>? _currentResponseController;
  bool _isGenerating = false;
  bool _wasCancelledThisTurn = false;
  bool get wasCancelledThisTurn => _wasCancelledThisTurn;

  // Generation ID system to filter stale tokens (race-condition safe)
  int _currentGenerationId = 0;
  int _activeGenerationId = 0;

  // Flag to indicate context needs reload after cancellation
  bool _needsContextReload = false;

  // Guard to prevent double-reload race condition
  bool _isReloadingContext = false;

  // FIX 4: Track whether mlock was used for the current model load
  bool _useMlock = false;

  // FIX 4C: Adaptive Thread Reduction for Long Sessions
  DateTime? _sessionStartTime;

  void markSessionStart() {
    _sessionStartTime ??= DateTime.now();
  }

  void resetSessionTimer() {
    _sessionStartTime = null;
  }

  int get _adaptiveThreads {
    if (_sessionStartTime == null) return _config.threads;
    final minutes = DateTime.now().difference(_sessionStartTime!).inMinutes;
    if (minutes < 10) return _config.threads;            // full speed
    if (minutes < 20) return (_config.threads - 1).clamp(2, 8); // -1 thread
    return (_config.threads - 2).clamp(2, 8);            // -2 threads
  }

  // FIX 4A: Post-Response Cooldown
  Duration get thermalCooldownDuration {
    switch (_config.tierName) {
      case 'Performance Mode': return const Duration(seconds: 1);
      case 'Balanced Mode':    return const Duration(seconds: 2);
      case 'Efficiency Mode':  return const Duration(seconds: 3);
      default:                 return const Duration(seconds: 2);
    }
  }

  LLMService(this._downloadService);

  /// Debug-only logging helper (silenced in release builds)
  void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }



  bool get isLoaded => _isInitialized;

  Future<void> loadModel() async {
    if (_isInitialized) {
      _log('Model already loaded, skipping...');
      return;
    }

    if (_isLoading) {
      _log('Model is currently loading, waiting...');
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!_isInitialized) {
        throw Exception('Model failed to load in concurrent process.');
      }
      return;
    }

    _isLoading = true;
    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      retryCount++;
      try {
        // 💾 CRITICAL MEMORY CHECK
        if (!await DeviceProfiler.hasEnoughMemory()) {
          throw Exception(
            'Not enough memory available. Please close other apps and try again.',
          );
        }

        _log('\u{1F504} Loading model (attempt $retryCount/$maxRetries)...');

        final modelPath = await _downloadService.getModelPath();
        if (!await File(modelPath).exists()) {
          throw Exception('Model file not found at: $modelPath');
        }

        _config = await DeviceProfiler.getBestConfig();

        // FIX 4: Check available RAM BEFORE model load to decide mlock
        _useMlock = await MemoryUtils.shouldUseMlock(_config);
        _log('\u{1F512} Model load: useMlock=$_useMlock, useMemorymap=${!_useMlock}');

        final loadCommand = LlamaLoad(
          path: modelPath,
          modelParams: ModelParams()
            ..nGpuLayers = _config.nGpuLayers
            ..useMemorymap = !_useMlock  // FIX 4: mmap off when mlocking
            ..useMemoryLock = _useMlock, // FIX 4: lock full model into RAM
          contextParams: ContextParams()
            ..nCtx = _config.contextSize
            ..nThreads = _adaptiveThreads     // Use adaptive, not fixed
            ..nBatch = _config.batchSize // Dynamic: 256/512/512 per tier (FIX 2)
            ..nPredict = _config.maxTokens,
          samplingParams: SamplerParams()
            ..temp = 0.7
            ..topP = 0.8
            ..topK = 40
            ..penaltyRepeat = 1.05,
          format: ChatMLFormat(),
        );

        _chatFormat = ChatMLFormat();
        _chatHistory = ChatHistory(keepRecentPairs: _config.historyLimit);
        _chatHistory!.addMessage(
          role: Role.system,
          content: _config.systemPrompt,
        );

        _llamaParent = LlamaParent(loadCommand);

        // Init with timeout
        await _llamaParent!.init().timeout(const Duration(seconds: 45));

        // Set up the main stream listener
        _streamSubscription = _llamaParent!.stream.listen(
          _handleToken,
          onError: _handleStreamError,
          onDone: _handleStreamDone,
        );

        _isInitialized = true;
        _isLoading = false;
        _log('\u{2705} Model loaded successfully');

        return; // Success!
      } on TimeoutException {
        _log('\u{23F1}\u{FE0F} Model init timed out (attempt $retryCount)');
        await _cleanupLoad();
        if (retryCount >= maxRetries) {
          _isLoading = false;
          _isInitialized = false;
          rethrow;
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        _log('\u{274C} Load failed (attempt $retryCount): $e');
        await _cleanupLoad();
        if (retryCount >= maxRetries) {
          _isLoading = false;
          _isInitialized = false;
          rethrow;
        }
        // Backoff: 5s, 8s, 11s
        await Future.delayed(Duration(seconds: (retryCount * 3) + 2));
      }
    }
  }

  // Define separate handlers for stream events to keep code clean
  void _handleToken(String token) {
    if (_needsContextReload) return;
    if (_activeGenerationId != _currentGenerationId) return;

    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.add(token);
    }
  }

  void _handleStreamError(Object error) {
    _log('\u{274C} [ISOLATE] Error: $error');
    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.addError(error);
      _currentResponseController!.close();
    }
    _isGenerating = false;
  }

  void _handleStreamDone() {
    _log('\u{1F3C1} [ISOLATE] Stream completed!');
    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.close();
    }
    _isGenerating = false;
  }

  Future<void> _cleanupLoad() async {
    resetSessionTimer();
    try {
      await _streamSubscription?.cancel();
      _llamaParent?.dispose();
    } catch (e) {
      /* ignore */
    }
    _streamSubscription = null;
    _llamaParent = null;
  }

  // Flag to abort generation even during context reload
  bool _abortCurrentGeneration = false;

  void pauseActiveGenerationIfNeeded() {
    if (_isGenerating) {
      _log('\u{23F8}\u{FE0F} [LIFECYCLE] Pausing active generation...');
      cancelGeneration();
    }
  }

  void cancelGeneration() {
    // 🛑 ALLOW cancel even if not "generating" (e.g. during reload)

    _log(
      '\u{1F6D1} [CANCEL] Canceling current generation (gen $_currentGenerationId)',
    );

    // ✅ Set flags IMMEDIATELY
    _isGenerating = false;
    _wasCancelledThisTurn = true;
    _abortCurrentGeneration = true; // Stop any pending reloads/setup
    _needsContextReload = true;

    // ✅ CRITICAL: Add a "cancel" token to break the await for loop
    // This ensures the loop receives an event and can check _isGenerating
    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.add(''); // Empty token triggers loop check
    }

    _currentResponseController?.close();
    _currentResponseController = null;
  }

  Future<void> resetContext() async {
    while (_isGenerating) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_chatHistory != null) {
      _log('\u{1F504} [CONTEXT] Resetting chat history...');
      _chatHistory = ChatHistory(keepRecentPairs: _config.historyLimit);
      _chatHistory!.addMessage(
        role: Role.system,
        content: _config.systemPrompt,
      );

      // Force reload for full reset (new chat)
      _needsContextReload = true;
      await reloadLlamaContext();
      _log('\u{2705} [CONTEXT] Reset complete');
    }
  }

  Future<void> reloadLlamaContext() async {
    if (_isReloadingContext || !_needsContextReload) return;
    if (_llamaParent == null) return;

    _isReloadingContext = true; // ← MUST be here — synchronous, no await before it

    try {
      // OOM GUARD: If RAM is critically low, wait and retry once before proceeding
      final availBefore = await MemoryUtils.readMemAvailableMb();
      if (availBefore < 400) {
        _log('\u{26A0}\u{FE0F} [CONTEXT] Low RAM (${availBefore}MB) — waiting 3s for OS to reclaim...');
        await Future.delayed(const Duration(seconds: 3));
        final availRetry = await MemoryUtils.readMemAvailableMb();
        if (availRetry < 400) {
          _log('\u{274C} [CONTEXT] RAM still critical (${availRetry}MB). Aborting reload.');
          _needsContextReload = true; // keep flag — try again next time
          return; // finally handles _isReloadingContext = false
        }
      }

      _log('\u{1F504} [CONTEXT] Reloading LlamaParent to clear KV cache...');
      _isInitialized = false; // 🛡️ Block streamResponse during isolate recreation

      await _streamSubscription?.cancel();
      _streamSubscription = null;

      _llamaParent?.dispose();
      _llamaParent = null;

      // FIX 2: Fixed 800ms isn't enough after mid-generation cancel.
      // Poll until OS reclaims native memory, max 5 seconds total.
      await Future.delayed(const Duration(milliseconds: 800));
      int pollMs = 0;
      while (pollMs < 4200) {
        final avail = await MemoryUtils.readMemAvailableMb();
        if (avail == 0 || avail > MemoryUtils.mlockMinFreeMb + 300) break; // +300MB safety margin
        await Future.delayed(const Duration(milliseconds: 300));
        pollMs += 300;
      }

      final modelPath = await _downloadService.getModelPath();

      // FIX 4: Check available RAM BEFORE reload to decide mlock
      _useMlock = await MemoryUtils.shouldUseMlock(_config);

      final loadCommand = LlamaLoad(
        path: modelPath,
        modelParams: ModelParams()
          ..nGpuLayers = _config.nGpuLayers
          ..useMemorymap = !_useMlock  // FIX 4: mmap off when mlocking
          ..useMemoryLock = _useMlock, // FIX 4: lock full model into RAM
        contextParams: ContextParams()
          ..nCtx = _config.contextSize
          ..nThreads = _adaptiveThreads     // Use adaptive, not fixed
          ..nBatch = _config.batchSize // Dynamic: 256/512/512 per tier (FIX 2)
          ..nPredict = _config.maxTokens,
        samplingParams: SamplerParams()
          ..temp = 0.7
          ..topP = 0.8
          ..topK = 40
          ..penaltyRepeat = 1.05,
        format: ChatMLFormat(),
      );

      _llamaParent = LlamaParent(loadCommand);
      await _llamaParent!.init();

      // Set up the main stream listener
      _streamSubscription = _llamaParent!.stream.listen(
        (token) {
          if (_needsContextReload) return;
          if (_activeGenerationId != _currentGenerationId) return;

          // 🔴 DISABLED: Token logging causes UI jank
          // _log('🔹 [ISOLATE] Token (gen $_currentGenerationId): "${token.length > 20 ? token.substring(0, 20) : token}"');
          if (_currentResponseController != null &&
              !_currentResponseController!.isClosed) {
            _currentResponseController!.add(token);
          }
        },
        onError: (error) {
          _log('\u{274C} [ISOLATE] Error: $error');
          if (_currentResponseController != null &&
              !_currentResponseController!.isClosed) {
            _currentResponseController!.addError(error);
            _currentResponseController!.close();
          }
          _isGenerating = false;
        },
        onDone: () {
          _log('\u{1F3C1} [ISOLATE] Stream completed!');
          if (_currentResponseController != null &&
              !_currentResponseController!.isClosed) {
            _currentResponseController!.close();
          }
          _isGenerating = false;
        },
      );

      _isInitialized = true; // ✅ Isolate ready, allow streamResponse
      _needsContextReload = false;
      _log('\u{2705} [CONTEXT] LlamaParent reloaded, KV cache cleared');
    } catch (e) {
      _log('\u{274C} [CONTEXT] Reload failed: $e');
      _isInitialized = false; // Keep blocked on failure
      rethrow;
    } finally {
      _isReloadingContext = false;
    }
  }

  void removeLastUserAndAssistantMessage() {
    if (_chatHistory != null && _chatHistory!.messages.isNotEmpty) {
      _log('\u{1F5D1}\u{FE0F} [CONTEXT] Removing last user message from history');

      // 🛡️ FIXED: First, remove all trailing empty/incomplete messages
      while (_chatHistory!.messages.isNotEmpty &&
          (_chatHistory!.messages.last.content.trim().isEmpty ||
              _chatHistory!.messages.last.content.trim() == '...' ||
              _chatHistory!.messages.last.content.contains(
                '_(Response stopped',
              ))) {
        _chatHistory!.messages.removeLast();
        _log('\u{1F5D1}\u{FE0F} [CONTEXT] Removed orphaned/empty message');
      }

      final newHistory = ChatHistory(keepRecentPairs: _config.historyLimit);

      int keepUntil = _chatHistory!.messages.length;

      // Find the last user message and remove it along with any following assistant
      for (int i = _chatHistory!.messages.length - 1; i >= 0; i--) {
        final msg = _chatHistory!.messages[i];
        if (msg.role == Role.user) {
          keepUntil = i;
          break;
        } else if (msg.role == Role.assistant) {
          keepUntil = i;
        }
      }

      for (var i = 0; i < keepUntil; i++) {
        final msg = _chatHistory!.messages[i];
        // Skip empty messages during rebuild
        if (msg.content.trim().isNotEmpty && msg.content.trim() != '...') {
          newHistory.addMessage(role: msg.role, content: msg.content);
        }
      }
      _chatHistory = newHistory;
      _log(
        '\u{2705} [CONTEXT] History cleaned, ${_chatHistory!.messages.length} messages remaining',
      );
    }
  }

  void removeLastAssistantMessage() {
    if (_chatHistory != null && _chatHistory!.messages.isNotEmpty) {
      final lastMsg = _chatHistory!.messages.last;
      if (lastMsg.role == Role.assistant) {
        _log('\u{1F5D1}\u{FE0F} [CONTEXT] Removing last assistant message from history');
        final newHistory = ChatHistory(keepRecentPairs: _config.historyLimit);
        for (var i = 0; i < _chatHistory!.messages.length - 1; i++) {
          final msg = _chatHistory!.messages[i];
          newHistory.addMessage(role: msg.role, content: msg.content);
        }
        _chatHistory = newHistory;
      }
    }
  }

  Stream<String> streamResponse(String message) async* {
    _currentGenerationId++;
    final myGenerationId = _currentGenerationId;

    _log(
      '\u{1F680} [ENTRY] streamResponse called with: "$message" (gen $myGenerationId)',
    );
    _log(
      '\u{1F50D} [STATE] _isInitialized: $_isInitialized, _isGenerating: $_isGenerating, _isReloadingContext: $_isReloadingContext',
    );

    // 🛡️ RACE CONDITION FIX: Wait for any in-progress context reload to finish
    // This prevents "No child isolate found" crash when user sends a message
    // immediately after clicking "New Chat" while the isolate is being recreated.
    if (_isReloadingContext) {
      _log('\u{23F3} [STREAM] Waiting for context reload to finish...');
      int reloadWait = 0;
      while (_isReloadingContext) {
        await Future.delayed(const Duration(milliseconds: 100));
        reloadWait++;
        if (reloadWait > 100) {
          // 10 second max wait
          _log('\u{274C} [STREAM] Context reload timed out after 10s');
          throw Exception('Model is restarting. Please try again in a moment.');
        }
      }
      _log('\u{2705} [STREAM] Context reload finished, proceeding...');
    }

    if (!_isInitialized ||
        _llamaParent == null ||
        _chatHistory == null ||
        _chatFormat == null) {
      _log('\u{274C} [ERROR] Model not loaded!');
      throw Exception('Model not loaded.');
    }

    // 🛡️ INPUT VALIDATION (Production safety)
    final trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty) {
      throw Exception('Cannot send empty message.');
    }
    if (trimmedMessage.length < 2) {
      throw Exception('Query too short. Please be more specific.');
    }
    if (trimmedMessage.length > 2000) {
      throw Exception('Message exceeds 2000 character limit.');
    }

    // Reset abort flag for new generation
    _abortCurrentGeneration = false;

    int waitCount = 0;
    while (_isGenerating) {
      if (_abortCurrentGeneration) break; // Break if this request was aborted
      waitCount++;
      _log('\u{23F3} [$waitCount] Waiting for previous generation...');
      await Future.delayed(const Duration(milliseconds: 100));
      if (waitCount > 30) {
        _log('\u{26A0}\u{FE0F} [TIMEOUT] Force canceling previous generation');
        cancelGeneration();
        await Future.delayed(const Duration(milliseconds: 100));
        break;
      }
    }

    // Check if we were cancelled while waiting
    if (_abortCurrentGeneration) {
      _log('\u{1F6D1} [STREAM] Aborted before starting');
      return;
    }

    // 🛡️ CRITICAL FIX: ALWAYS reload after cancellation to prevent stale tokens
    // The old "skip for quick follow-ups" logic caused a bug where cancelled
    // generation tokens leaked into the next question's response!
    if (_needsContextReload) {
      _log('\u{26A0}\u{FE0F} [CONTEXT] Reload required after previous cancellation');
      await reloadLlamaContext();
    }

    // Check AGAIN after reload (user might have clicked stop during reload)
    if (_abortCurrentGeneration) {
      _log('\u{1F6D1} [STREAM] Aborted during context reload');
      return;
    }

    _activeGenerationId = myGenerationId;
    // Set running flag (will be checked again below)
    _isGenerating = true;
    _wasCancelledThisTurn = false;

    // 1. SILENT CONTEXT INJECTION
    String effectivePrompt = message;
    final lowerMsg = message.toLowerCase().trim();

    // 🛡️ FIXED: Use .any() with .startsWith() for correct greeting detection
    final greetings = [
      'hi',
      'hello',
      'hey',
      'greetings',
      'hola',
      'thanks',
      'thank you',
    ];
    final cleanedMsg = lowerMsg.replaceAll(RegExp(r'[^\w\s]'), '').trim();
    final isGreeting = greetings.any((g) => cleanedMsg.startsWith(g));

    // 🔧 OPTIMIZED: Helps the model format correctly even on short queries
    if (_config.enableSmartContext && message.length < 20 && !isGreeting) {
      // Only for very short queries (< 20 chars), force structure with bullet points
      effectivePrompt =
          '$message (explain simply with bullet points)'; // Forces formatting!
    }

    _log('\u{1F4AC} [STREAM] Starting for: "$message" (Hidden: "$effectivePrompt")');

    _chatHistory!.addMessage(role: Role.user, content: message);
    _pruneHistoryIfNeeded();
    _log(
      '\u{1F4DC} [CONTEXT] History: ${_chatHistory!.messages.length} msgs (Pruning: ${_config.historyLimit} pairs)',
    );

    // Build prompt manually
    String formattedPrompt =
        '<|im_start|>system\n${_config.systemPrompt}<|im_end|>\n';

    for (int i = 0; i < _chatHistory!.messages.length - 1; i++) {
      final msg = _chatHistory!.messages[i];

      // SAFETY CHECK: Skip empty messages
      if (msg.content.trim().isEmpty) {
        _log('\u{26A0}\u{FE0F} [PROMPT] Skipping empty ${msg.role.name} message at index $i');
        continue;
      }

      if (msg.role != Role.system) {
        formattedPrompt +=
            '<|im_start|>${msg.role.name}\n${msg.content}\n<|im_end|>\n';
      }
    }

    formattedPrompt += '<|im_start|>user\n$effectivePrompt\n<|im_end|>\n';
    formattedPrompt += '<|im_start|>assistant\n';

    _log('\u{1F50D} PROMPT:');
    _log(formattedPrompt);
    _log('---END---');

    if (_currentResponseController != null) {
      await _currentResponseController!.close();
    }

    _log('\u{1F504} [STREAM] New controller...');
    _currentResponseController = StreamController<String>();

    await Future.delayed(const Duration(milliseconds: 50));

    // CHECK ABORT one last time before committing to isolate
    if (_abortCurrentGeneration) {
      _log('\u{1F6D1} [STREAM] Aborted prompt sending');
      _currentResponseController?.close();
      return;
    }

    _log('\u{1F4E4} [STREAM] Sending to isolate...');
    _llamaParent!.sendPrompt(formattedPrompt);

    String fullResponse = '';
    Timer? timeoutTimer;
    bool hasReceivedFirstToken = false;
    final startTime = DateTime.now(); // Track response timing

    // 2. SMART TIMEOUT with Dynamic Duration based on response length
    void resetTimeout({bool isShort = false}) {
      timeoutTimer?.cancel();

      Duration duration;
      if (!hasReceivedFirstToken) {
        // Initial: Wait up to 45s for model warmup
        duration = const Duration(seconds: 45);
      } else {
        // After first token:
        if (isShort) {
          // ✅ AGGRESSIVE: 1.5s after sentence ending (., !, ?)
          duration = const Duration(milliseconds: 1500);
        } else {
          // ✅ AGGRESSIVE: 2s base timeout + small extension for long responses
          // This ensures we close quickly after the model stops generating
          final currentLength = fullResponse.length;

          // Start with 2s base, add 1s per 300 chars (max 8s total)
          final extraTime = (currentLength ~/ 300) * 1;
          final totalTimeout = 2 + extraTime.clamp(0, 6);

          duration = Duration(seconds: totalTimeout);
        }
      }

      timeoutTimer = Timer(duration, () {
        final timeoutType = !hasReceivedFirstToken
            ? "Initial 45s"
            : (isShort ? "Smart 1.5s" : "Dynamic ${duration.inSeconds}s");
        _log(
          '\u{23F1}\u{FE0F} [TIMEOUT] $timeoutType triggered (${fullResponse.length} chars)',
        );
        // Only reload context if model completely failed to start (45s with no tokens).
        // Dynamic/Smart timeouts are NORMAL completion (model stopped → timer fires).
        // Setting _needsContextReload on normal completions caused the "Amnesia Loop"
        // where every message triggered a full KV cache reload + re-process all history.
        if (!hasReceivedFirstToken) {
          _needsContextReload =
              true; // Real failure: model didn't produce any output
        }
        _currentResponseController?.close();
      });
    }

    resetTimeout(isShort: false);

    try {
      await for (final token in _currentResponseController!.stream) {
        // ✅ CRITICAL: Check if cancelled at START of each iteration
        // This allows immediate exit when user clicks stop
        if (!_isGenerating || _activeGenerationId != myGenerationId) {
          _log('\u{1F6D1} [STREAM] Cancelled detected - breaking immediately!');
          timeoutTimer?.cancel();
          break;
        }

        // Mark first token received - switch from 30s to 10s base timeout
        if (!hasReceivedFirstToken) {
          hasReceivedFirstToken = true;
          final firstTokenMs = DateTime.now()
              .difference(startTime)
              .inMilliseconds;
          _log(
            '\u{1F3AF} [STREAM] First token in ${firstTokenMs}ms! Now using 2s base timeout.',
          );
          // DON'T call resetTimeout here - let the sentence detection below handle it
          // This prevents premature timeouts on early tokens
        }

        // 3. ROBUST EOS HANDLING - Close stream IMMEDIATELY when model is done
        final eosEnd =
            '<'
            '|im_end|'
            '>';
        final eosText =
            '<'
            '|endoftext|'
            '>';
        final eosSlash =
            '<'
            '/s'
            '>';

        if (token.contains(eosEnd) ||
            token.contains(eosText) ||
            token.contains(eosSlash)) {
          final cleanToken = token
              .replaceAll(eosEnd, '')
              .replaceAll(eosText, '')
              .replaceAll(eosSlash, '');
          if (cleanToken.trim().isNotEmpty) {
            fullResponse += cleanToken;
            yield cleanToken;
          }
          _log('\u{1F3C1} [STREAM] EOS detected - closing stream immediately!');

          // ✅ CRITICAL: Cancel timer BEFORE break to prevent delayed state reset
          timeoutTimer?.cancel();
          _isGenerating = false;

          break; // Exit immediately - no more waiting!
        }

        // ✅ Skip empty tokens (used as cancel signal)
        if (token.isEmpty) continue;

        // Normal token processing
        fullResponse += token;
        yield token;

        // 🛡️ FIXED: Check COMPLETE response for sentence endings, not single tokens
        // ✅ LOWERED from 50 to 15 chars to catch short responses like greetings
        final minResponseLength = 15;
        final lastChars = fullResponse.length > 3
            ? fullResponse.substring(fullResponse.length - 3)
            : fullResponse;
        final isSentenceEnd =
            fullResponse.length >= minResponseLength &&
            (lastChars.endsWith('. ') ||
                lastChars.endsWith('! ') ||
                lastChars.endsWith('? ') ||
                lastChars.endsWith('.\n') ||
                lastChars.endsWith('!\n') ||
                lastChars.endsWith('?\n') ||
                (fullResponse.endsWith('.') && token.trim().isEmpty) ||
                (fullResponse.endsWith('!') && token.trim().isEmpty) ||
                (fullResponse.endsWith('?') && token.trim().isEmpty));
        resetTimeout(isShort: isSentenceEnd);
      }
    } catch (e) {
      _log('\u{274C} [STREAM] Error: $e');
      _needsContextReload = true; // Error = corrupted state, must reload
      // User-friendly error mapping
      if (e is TimeoutException) {
        throw Exception(
          'Response took too long. Please try a shorter question.',
        );
      } else if (e.toString().contains('context') ||
          e.toString().contains('memory')) {
        throw Exception('Chat history is too long. Please start a new chat.');
      }
      // Re-throw formatted exception or generic one
      throw Exception(
        'Failed to generate response: ${e.toString().replaceAll("Exception:", "").trim()}',
      );
    } finally {
      timeoutTimer?.cancel();
      _isGenerating = false;

      if (_wasCancelledThisTurn) {
        _log('\u{26A0}\u{FE0F} [STREAM] Cancelled – skipping history save');
      } else {
        // Log total response time and preview
        final totalMs = DateTime.now().difference(startTime).inMilliseconds;
        _log(
          '\u{2705} [STREAM] Complete in ${totalMs}ms (${fullResponse.length} chars)',
        );

        // ✅ ADD: Log response preview for debugging
        final preview = fullResponse.length > 100
            ? '${fullResponse.substring(0, 100)}...'
            : fullResponse;
        _log('\u{1F4DD} [RESPONSE] "$preview"');

        // Save the clean response to history
        final eosEndClean =
            '<'
            '|im_end|'
            '>';
        // 🛡️ OOM PROTECTION: Truncate very long responses
        final maxLength = _config.maxTokens * 4; // ~4 chars per token estimate
        final cleanResponse = fullResponse.replaceAll(eosEndClean, '').trim();
        final safeResponse = cleanResponse.length > maxLength
            ? '${cleanResponse.substring(0, maxLength)}...'
            : cleanResponse;
        _chatHistory!.addMessage(role: Role.assistant, content: safeResponse);
      }
    }
  }

  // 🛡️ RESOURCE MANAGEMENT: Unload model on app pause/exit
  Future<void> unloadModel() async {
    if (!_isInitialized) return;

    _log('\u{1F9F9} [LIFECYCLE] Unloading model to free resources...');

    // Stop currently generation if any
    cancelGeneration();

    _isGenerating = false;
    _currentResponseController?.close();

    await _streamSubscription?.cancel();
    _streamSubscription = null;

    _llamaParent?.dispose();
    _llamaParent = null;

    _chatHistory = null;
    _chatFormat = null;
    _isInitialized = false;
    _needsContextReload = false;
    _isReloadingContext = false;

    resetSessionTimer();
    _log('\u{2705} [LIFECYCLE] Model unloaded successfully');
  }

  // 🛡️ MEMORY MANAGEMENT: Prevent history from growing too large
  void _pruneHistoryIfNeeded() {
    if (_chatHistory == null) return;

    // Keep system prompt + last 50 messages
    const maxMessages = 50;

    if (_chatHistory!.messages.length > maxMessages) {
      final systemMsg = _chatHistory!.messages.first; // Retain system prompt
      final recentMessages = _chatHistory!.messages.sublist(
        _chatHistory!.messages.length - maxMessages + 1,
      );

      _chatHistory = ChatHistory(keepRecentPairs: _config.historyLimit);
      _chatHistory!.addMessage(
        role: systemMsg.role,
        content: systemMsg.content,
      );

      for (var msg in recentMessages) {
        _chatHistory!.addMessage(role: msg.role, content: msg.content);
      }

      _log('\u{1F9F9} [MEMORY] Pruned chat history to $maxMessages messages');
    }
  }
}

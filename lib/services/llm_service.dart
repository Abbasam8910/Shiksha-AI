import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'model_download_service.dart';
import 'device_config_service.dart';

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

  // Generation ID system to filter stale tokens (race-condition safe)
  int _currentGenerationId = 0;
  int _activeGenerationId = 0;

  // Flag to indicate context needs reload after cancellation
  bool _needsContextReload = false;

  // Guard to prevent double-reload race condition
  bool _isReloadingContext = false;

  LLMService(this._downloadService);

  /// Debug-only logging helper (silenced in release builds)
  void _log(String message) {
    if (kDebugMode) print(message);
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
      return;
    }

    _isLoading = true;
    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        // 💾 CRITICAL MEMORY CHECK
        if (!await DeviceProfiler.hasEnoughMemory()) {
          throw Exception(
            'Not enough memory available. Please close other apps and try again.',
          );
        }

        _log('🔄 Loading model (attempt ${retryCount + 1}/$maxRetries)...');

        final modelPath = await _downloadService.getModelPath();
        if (!await File(modelPath).exists()) {
          throw Exception('Model file not found at: $modelPath');
        }

        _config = await DeviceProfiler.getBestConfig();

        final loadCommand = LlamaLoad(
          path: modelPath,
          modelParams: ModelParams()
            ..nGpuLayers = _config.nGpuLayers
            ..useMemorymap = true
            ..useMemoryLock = false,
          contextParams: ContextParams()
            ..nCtx = _config.contextSize
            ..nThreads = _config.threads
            ..nBatch = 512
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

        _streamSubscription = _llamaParent!.stream.listen(
          _handleToken,
          onError: _handleStreamError,
          onDone: _handleStreamDone,
        );

        _isInitialized = true;
        _isLoading = false;
        _log('✅ Model loaded successfully');
        return; // Success!
      } on TimeoutException {
        retryCount++;
        _log('⏱️ Model init timed out (attempt $retryCount)');
        await _cleanupLoad();
        if (retryCount >= maxRetries) rethrow;
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        retryCount++;
        _log('❌ Load failed (attempt $retryCount): $e');
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
    _log('❌ [ISOLATE] Error: $error');
    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.addError(error);
      _currentResponseController!.close();
    }
    _isGenerating = false;
  }

  void _handleStreamDone() {
    _log('🏁 [ISOLATE] Stream completed!');
    if (_currentResponseController != null &&
        !_currentResponseController!.isClosed) {
      _currentResponseController!.close();
    }
    _isGenerating = false;
  }

  Future<void> _cleanupLoad() async {
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

  void cancelGeneration() {
    // 🛑 ALLOW cancel even if not "generating" (e.g. during reload)

    _log(
      '🛑 [CANCEL] Canceling current generation (gen $_currentGenerationId)',
    );

    // ✅ Set flags IMMEDIATELY
    _isGenerating = false;
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
      _log('🔄 [CONTEXT] Resetting chat history...');
      _chatHistory = ChatHistory(keepRecentPairs: _config.historyLimit);
      _chatHistory!.addMessage(
        role: Role.system,
        content: _config.systemPrompt,
      );

      await reloadLlamaContext();
      _log('✅ [CONTEXT] Reset complete');
    }
  }

  Future<void> reloadLlamaContext() async {
    // 🛡️ RACE CONDITION FIX: Check both flags
    if (_isReloadingContext || !_needsContextReload) {
      _log('⚠️ [CONTEXT] Reload skipped (in progress or not needed)');
      return;
    }
    if (!_isInitialized || _llamaParent == null) return;

    _isReloadingContext = true;

    try {
      _log('🔄 [CONTEXT] Reloading LlamaParent to clear KV cache...');

      await _streamSubscription?.cancel();
      _streamSubscription = null;

      _llamaParent?.dispose();
      _llamaParent = null;

      final modelPath = await _downloadService.getModelPath();

      final loadCommand = LlamaLoad(
        path: modelPath,
        modelParams: ModelParams()
          ..nGpuLayers = _config.nGpuLayers
          ..useMemorymap = true
          ..useMemoryLock = false,
        contextParams: ContextParams()
          ..nCtx = _config.contextSize
          ..nThreads = _config.threads
          ..nBatch = 512
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
          _log('❌ [ISOLATE] Error: $error');
          if (_currentResponseController != null &&
              !_currentResponseController!.isClosed) {
            _currentResponseController!.addError(error);
            _currentResponseController!.close();
          }
          _isGenerating = false;
        },
        onDone: () {
          _log('🏁 [ISOLATE] Stream completed!');
          if (_currentResponseController != null &&
              !_currentResponseController!.isClosed) {
            _currentResponseController!.close();
          }
          _isGenerating = false;
        },
      );

      _needsContextReload = false;
      _log('✅ [CONTEXT] LlamaParent reloaded, KV cache cleared');
    } catch (e) {
      _log('❌ [CONTEXT] Reload failed: $e');
      rethrow;
    } finally {
      _isReloadingContext = false;
    }
  }

  void removeLastUserAndAssistantMessage() {
    if (_chatHistory != null && _chatHistory!.messages.isNotEmpty) {
      _log('🗑️ [CONTEXT] Removing last user message from history');

      // 🛡️ FIXED: First, remove all trailing empty/incomplete messages
      while (_chatHistory!.messages.isNotEmpty &&
          (_chatHistory!.messages.last.content.trim().isEmpty ||
              _chatHistory!.messages.last.content.trim() == '...' ||
              _chatHistory!.messages.last.content.contains(
                '_(Response stopped',
              ))) {
        _chatHistory!.messages.removeLast();
        _log('🗑️ [CONTEXT] Removed orphaned/empty message');
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
        '✅ [CONTEXT] History cleaned, ${_chatHistory!.messages.length} messages remaining',
      );
    }
  }

  void removeLastAssistantMessage() {
    if (_chatHistory != null && _chatHistory!.messages.isNotEmpty) {
      final lastMsg = _chatHistory!.messages.last;
      if (lastMsg.role == Role.assistant) {
        _log('🗑️ [CONTEXT] Removing last assistant message from history');
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
      '🚀 [ENTRY] streamResponse called with: "$message" (gen $myGenerationId)',
    );
    _log(
      '🔍 [STATE] _isInitialized: $_isInitialized, _isGenerating: $_isGenerating',
    );

    if (!_isInitialized ||
        _llamaParent == null ||
        _chatHistory == null ||
        _chatFormat == null) {
      _log('❌ [ERROR] Model not loaded!');
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
      _log('⏳ [$waitCount] Waiting for previous generation...');
      await Future.delayed(const Duration(milliseconds: 100));
      if (waitCount > 30) {
        _log('⚠️ [TIMEOUT] Force canceling previous generation');
        cancelGeneration();
        await Future.delayed(const Duration(milliseconds: 100));
        break;
      }
    }

    // Check if we were cancelled while waiting
    if (_abortCurrentGeneration) {
      _log('🛑 [STREAM] Aborted before starting');
      return;
    }

    // 🛡️ CRITICAL FIX: ALWAYS reload after cancellation to prevent stale tokens
    // The old "skip for quick follow-ups" logic caused a bug where cancelled
    // generation tokens leaked into the next question's response!
    if (_needsContextReload) {
      _log('⚠️ [CONTEXT] Reload required after previous cancellation');
      await reloadLlamaContext();
    }

    // Check AGAIN after reload (user might have clicked stop during reload)
    if (_abortCurrentGeneration) {
      _log('🛑 [STREAM] Aborted during context reload');
      return;
    }

    _activeGenerationId = myGenerationId;
    // Set running flag (will be checked again below)
    _isGenerating = true;

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

    // 🔧 OPTIMIZED: Shorter injection saves ~12 tokens per query
    if (_config.enableSmartContext && message.length < 20 && !isGreeting) {
      // Only for very short queries (< 20 chars), use minimal injection
      effectivePrompt =
          '$message (explain for students)'; // Only 3 extra tokens!
    }

    _log('💬 [STREAM] Starting for: "$message" (Hidden: "$effectivePrompt")');

    _chatHistory!.addMessage(role: Role.user, content: message);
    _pruneHistoryIfNeeded();
    _log(
      '📜 [CONTEXT] History: ${_chatHistory!.messages.length} msgs (Pruning: ${_config.historyLimit} pairs)',
    );

    // Build prompt manually
    String formattedPrompt =
        '<|im_start|>system\n${_config.systemPrompt}<|im_end|>\n';

    for (int i = 0; i < _chatHistory!.messages.length - 1; i++) {
      final msg = _chatHistory!.messages[i];

      // SAFETY CHECK: Skip empty messages
      if (msg.content.trim().isEmpty) {
        _log('⚠️ [PROMPT] Skipping empty ${msg.role.name} message at index $i');
        continue;
      }

      if (msg.role != Role.system) {
        formattedPrompt +=
            '<|im_start|>${msg.role.name}\n${msg.content}\n<|im_end|>\n';
      }
    }

    formattedPrompt += '<|im_start|>user\n$effectivePrompt\n<|im_end|>\n';
    formattedPrompt += '<|im_start|>assistant\n';

    _log('🔍 PROMPT:');
    _log(formattedPrompt);
    _log('---END---');

    if (_currentResponseController != null) {
      await _currentResponseController!.close();
    }

    _log('🔄 [STREAM] New controller...');
    _currentResponseController = StreamController<String>();

    await Future.delayed(const Duration(milliseconds: 50));

    // CHECK ABORT one last time before committing to isolate
    if (_abortCurrentGeneration) {
      _log('🛑 [STREAM] Aborted prompt sending');
      _currentResponseController?.close();
      return;
    }

    _log('📤 [STREAM] Sending to isolate...');
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
          '⏱️ [TIMEOUT] $timeoutType triggered (${fullResponse.length} chars)',
        );
        _needsContextReload = true;
        _currentResponseController?.close();
      });
    }

    resetTimeout(isShort: false);

    try {
      await for (final token in _currentResponseController!.stream) {
        // ✅ CRITICAL: Check if cancelled at START of each iteration
        // This allows immediate exit when user clicks stop
        if (!_isGenerating || _activeGenerationId != myGenerationId) {
          _log('🛑 [STREAM] Cancelled detected - breaking immediately!');
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
            '🎯 [STREAM] First token in ${firstTokenMs}ms! Now using 2s base timeout.',
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
          _log('🏁 [STREAM] EOS detected - closing stream immediately!');

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
      _log('❌ [STREAM] Error: $e');
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

      // Log total response time and preview
      final totalMs = DateTime.now().difference(startTime).inMilliseconds;
      _log(
        '✅ [STREAM] Complete in ${totalMs}ms (${fullResponse.length} chars)',
      );

      // ✅ ADD: Log response preview for debugging
      final preview = fullResponse.length > 100
          ? '${fullResponse.substring(0, 100)}...'
          : fullResponse;
      _log('📝 [RESPONSE] "$preview"');

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

  // 🛡️ RESOURCE MANAGEMENT: Unload model on app pause/exit
  Future<void> unloadModel() async {
    if (!_isInitialized) return;

    _log('🧹 [LIFECYCLE] Unloading model to free resources...');

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

    _log('✅ [LIFECYCLE] Model unloaded successfully');
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

      _log('🧹 [MEMORY] Pruned chat history to $maxMessages messages');
    }
  }
}

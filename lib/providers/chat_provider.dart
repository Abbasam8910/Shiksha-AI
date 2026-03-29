import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/llm_service.dart';
import '../utils/math_formatter.dart';
import 'download_provider.dart';

final chatBoxProvider = Provider<Box<ChatSession>>((ref) {
  throw UnimplementedError('chatBoxProvider not initialized');
});

final llmServiceProvider = Provider<LLMService>((ref) {
  final downloadService = ref.watch(modelDownloadServiceProvider);
  return LLMService(downloadService);
});

final currentSessionIdProvider = StateProvider<String?>((ref) => null);
final currentChatSubjectProvider = StateProvider<String?>((ref) => null);

// Track if LLM is currently generating a response
final isGeneratingProvider = StateProvider<bool>((ref) => false);

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  final Box<ChatSession> _box;
  final LLMService _llmService;
  final Ref _ref;
  StreamSubscription<String>? _currentInferenceSubscription;
  DateTime? _lastUIUpdate; // For UI throttling
  DateTime? _lastCancelTime; // For cancel debouncing

  ChatNotifier(this._box, this._llmService, this._ref) : super([]);

  Future<void> loadSession(String sessionId) async {
    final session = _box.get(sessionId);
    if (session != null) {
      state = session.messages;
      _ref.read(currentSessionIdProvider.notifier).state = sessionId;
    }
  }

  Future<void> startNewChat({String? subject}) async {
    if (kDebugMode) print('🆕 [PROVIDER] Starting new chat...');

    // Cancel any ongoing generation first
    if (_currentInferenceSubscription != null) {
      if (kDebugMode) {
        print('🛑 [PROVIDER] Canceling ongoing generation for new chat...');
      }
      await _currentInferenceSubscription?.cancel();
      _currentInferenceSubscription = null;
      _llmService.cancelGeneration();
    }

    // Reset UI state
    state = [];
    _ref.read(currentSessionIdProvider.notifier).state = null;
    _ref.read(currentChatSubjectProvider.notifier).state = subject;
    _ref.read(isGeneratingProvider.notifier).state = false;

    // Reset LLM context for new chat
    await _llmService.resetContext();
    _llmService.resetSessionTimer();

    // Ensure model is loaded when starting a chat
    if (!_llmService.isLoaded) {
      try {
        await _llmService.loadModel();
      } catch (e) {
        if (kDebugMode) print('Error loading model on new chat: $e');
      }
    }

    if (kDebugMode) print('✅ [PROVIDER] New chat started with clean state');
  }

  Future<void> addMessage(String content, String role) async {
    // 1. Add User Message
    final userMessage = ChatMessage(
      role: role,
      content: content,
      timestamp: DateTime.now(),
    );
    state = [...state, userMessage];
    await _saveToHive();

    if (role == 'user') {
      // 2. Prepare for AI Response
      // Ensure model is loaded
      if (!_llmService.isLoaded) {
        try {
          if (kDebugMode) print('🔄 Loading model for first time...');
          await _llmService.loadModel();
        } catch (e) {
          _addErrorMessage('Failed to load AI model: $e');
          return;
        }
      }

      // Create a placeholder assistant message
      final assistantMessage = ChatMessage(
        role: 'assistant',
        content: '...', // Show thinking indicator
        timestamp: DateTime.now(),
      );
      state = [...state, assistantMessage];

      // Cancel any previous inference stream (only if active!)
      if (_currentInferenceSubscription != null) {
        if (kDebugMode) print('🛑 [PROVIDER] Canceling previous stream...');
        await _currentInferenceSubscription?.cancel();
        _currentInferenceSubscription = null;
        // Only cancel in service if we had an active stream
        _llmService.cancelGeneration();
        await Future.delayed(
          const Duration(milliseconds: 100),
        ); // Give service time to reset
      }

      // Stream Response (non-blocking)
      String fullResponse = '';

      // Set generating state to true
      _ref.read(isGeneratingProvider.notifier).state = true;

      // Listen to the stream from managed isolate (non-blocking!)
      if (kDebugMode) print('📡 [PROVIDER] Starting stream for: "$content"');
      _llmService.markSessionStart();
      final stream = _llmService.streamResponse(content);
      _currentInferenceSubscription = stream.listen(
        (token) {
          fullResponse += token;

          // UI Throttling: Only update every 100ms to reduce frame skips
          final now = DateTime.now();
          if (_lastUIUpdate == null ||
              now.difference(_lastUIUpdate!).inMilliseconds > 100) {
            _lastUIUpdate = now;

            final updatedMessages = List<ChatMessage>.from(state);
            if (updatedMessages.isNotEmpty) {
              updatedMessages.last = ChatMessage(
                role: 'assistant',
                content: MathFormatter.format(fullResponse),
                timestamp: DateTime.now(),
              );
              state = updatedMessages;
            }
          }
        },
        onDone: () async {
          // Final update with complete response
          final updatedMessages = List<ChatMessage>.from(state);
          if (updatedMessages.isNotEmpty) {
            // ✅ Apply math formatting for subscripts/superscripts
            final String finalContent = fullResponse.isEmpty 
               ? (_llmService.wasCancelledThisTurn ? '' : 'No response generated.')
               : fullResponse;
               
            final formattedResponse = MathFormatter.format(finalContent);
            updatedMessages.last = ChatMessage(
              role: 'assistant',
              content: formattedResponse,
              timestamp: DateTime.now(),
            );
            state = updatedMessages;
          }

          // Save final state to Hive
          await _saveToHive();
          _currentInferenceSubscription = null;

          // Reset generating state
          await Future.delayed(_llmService.thermalCooldownDuration);
          _ref.read(isGeneratingProvider.notifier).state = false;
        },
        onError: (e, stackTrace) {
          if (kDebugMode) print('❌ Error generating response: $e');
          _addErrorMessage('Error generating response: $e');
          _currentInferenceSubscription = null;

          // Reset generating state on error
          _ref.read(isGeneratingProvider.notifier).state = false;
        },
      );
    }
  }

  // Cancel the current generation and reset state
  Future<void> cancelCurrentGeneration() async {
    // ✅ Guard: Only cancel if we have an active subscription
    if (_currentInferenceSubscription == null) {
      if (kDebugMode) print('⏸️ [PROVIDER] No active generation to cancel');
      return;
    }

    // ✅ Debounce: Ignore rapid cancel clicks (within 1 second now)
    final now = DateTime.now();
    if (_lastCancelTime != null &&
        now.difference(_lastCancelTime!).inMilliseconds < 1000) {
      if (kDebugMode) print('⏸️ [PROVIDER] Cancel debounced (too fast)');
      return;
    }
    _lastCancelTime = now;

    if (kDebugMode) print('🛑 [PROVIDER] Manually canceling generation...');

    // ✅ CRITICAL: Set subscription to null FIRST to prevent re-entry
    final subscription = _currentInferenceSubscription;
    _currentInferenceSubscription = null;

    // Cancel the stream subscription
    await subscription?.cancel();

    // Cancel in the service (this marks tokens as stale)
    _llmService.cancelGeneration();

    // Only remove from LLM history if response was empty/placeholder
    // Don't remove if there was actual content generated!
    final lastMessage = state.isNotEmpty ? state.last : null;
    final hasContent =
        lastMessage != null &&
        lastMessage.role == 'assistant' &&
        lastMessage.content != '...' &&
        lastMessage.content.isNotEmpty &&
        !lastMessage.content.contains('_(Response stopped by user)_');

    if (!hasContent) {
      // Clear the user message and partial response from LLM's chat history
      _llmService.removeLastUserAndAssistantMessage();
    }

    // Update last message to show it was stopped (only once!)
    final updatedMessages = List<ChatMessage>.from(state);
    if (updatedMessages.isNotEmpty &&
        updatedMessages.last.role == 'assistant') {
      final currentContent = updatedMessages.last.content;

      // ✅ Only add "stopped" text if not already present
      if (!currentContent.contains('_(Response stopped by user)_')) {
        updatedMessages.last = ChatMessage(
          role: 'assistant',
          content: currentContent == '...'
              ? '_(Response stopped by user)_'
              : '$currentContent\n\n_(Response stopped by user)_',
          timestamp: DateTime.now(),
        );
        state = updatedMessages;
        await _saveToHive();
      }
    }

    // Reset generating state
    _ref.read(isGeneratingProvider.notifier).state = false;
    if (kDebugMode) print('✅ [PROVIDER] Generation canceled successfully');
  }

  String _generateSmartTitle(String message) {
    // Remove common question words and extract key content
    String cleaned = message.toLowerCase();

    // Remove question words
    final questionWords = [
      'what is',
      'what are',
      'how to',
      'how do',
      'why',
      'when',
      'where',
      'who',
      'explain',
      'tell me about',
      'help me with',
      'can you',
    ];
    for (var word in questionWords) {
      cleaned = cleaned.replaceAll(word, '').trim();
    }

    // Remove punctuation
    cleaned = cleaned.replaceAll(RegExp(r'[?!.,]'), '');

    // Capitalize first letter of each word
    final words = cleaned.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      return message.length > 30 ? '${message.substring(0, 30)}...' : message;
    }

    // Take first 3-4 meaningful words
    final titleWords = words
        .take(4)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .toList();
    return titleWords.join(' ');
  }

  void deleteSession(String sessionId) {
    // Delete from Hive storage
    _box.delete(sessionId);

    // If this was the current session, clear it
    if (_ref.read(currentSessionIdProvider) == sessionId) {
      state = [];
      _ref.read(currentSessionIdProvider.notifier).state = null;
    }
  }

  Future<void> clearAllChats() async {
    // Clear all sessions from Hive
    await _box.clear();

    // Clear current state
    state = [];
    _ref.read(currentSessionIdProvider.notifier).state = null;

    // Reset context
    await _llmService.resetContext();
  }

  void _addErrorMessage(String error) {
    final errorMessage = ChatMessage(
      role: 'assistant',
      content: 'Error: $error',
      timestamp: DateTime.now(),
    );
    state = [...state, errorMessage];
    _saveToHive();
  }

  Future<void> _saveToHive() async {
    final sessionId = _ref.read(currentSessionIdProvider);
    if (sessionId == null) {
      // Create new session
      final newId = const Uuid().v4();

      // Auto-generate smart title from first USER message
      String title = 'New Chat';
      if (state.isNotEmpty) {
        // Find first user message
        final userMessages = state.where((m) => m.role == 'user');
        if (userMessages.isNotEmpty) {
          title = _generateSmartTitle(userMessages.first.content);
        }
      }

      final newSession = ChatSession(
        id: newId,
        title: title,
        messages: state,
        lastUpdated: DateTime.now(),
        subject: _ref.read(currentChatSubjectProvider),
      );
      await _box.put(newId, newSession);
      _ref.read(currentSessionIdProvider.notifier).state = newId;
    } else {
      // Update existing session
      final session = _box.get(sessionId);
      if (session != null) {
        // Create new session object to force update
        final updatedSession = ChatSession(
          id: session.id,
          title: session.title,
          messages: state,
          lastUpdated: DateTime.now(),
          subject: session.subject, // Keep existing subject
        );
        await _box.put(sessionId, updatedSession);
      }
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, List<ChatMessage>>((
  ref,
) {
  final box = ref.watch(chatBoxProvider);
  final llmService = ref.watch(llmServiceProvider);
  return ChatNotifier(box, llmService, ref);
});

// This provider watches the box and updates when it changes
final chatSessionsProvider = Provider<List<ChatSession>>((ref) {
  final box = ref.watch(chatBoxProvider);
  // Force rebuild by watching the box
  ref.watch(chatProvider); // This ensures updates when chats change
  return box.values.toList()
    ..sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
});

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/chat_provider.dart';
import '../widgets/app_drawer.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // ✅ NEW: Silent background loading states
  bool _isModelLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initializeModelSilently();
  }

  /// ✅ NEW: Load model silently in background - no blocking UI
  Future<void> _initializeModelSilently() async {
    try {
      final llmService = ref.read(llmServiceProvider);
      await llmService.loadModel();
      if (mounted) {
        setState(() => _isModelLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isModelLoading = false;
          _hasError = true;
        });
        // Show error as a snackbar, not blocking dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('AI initialization failed: ${e.toString()}'),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: () {
                setState(() {
                  _isModelLoading = true;
                  _hasError = false;
                });
                _initializeModelSilently();
              },
            ),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    }
  }

  void _handleSubmitted(String text) {
    if (text.trim().isEmpty) return;

    // ✅ If model still loading, show friendly message
    if (_isModelLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('AI is still warming up... Try again in a moment!'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // ✅ If there was an error, prompt retry
    if (_hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('AI failed to load. Tap to retry.'),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: () {
              setState(() {
                _isModelLoading = true;
                _hasError = false;
              });
              _initializeModelSilently();
            },
          ),
        ),
      );
      return;
    }

    // ✅ NEW: Double-check model is actually loaded (catches edge cases)
    final llmService = ref.read(llmServiceProvider);
    if (!llmService.isLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('AI is not ready. Tap to retry loading.'),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: () {
              setState(() {
                _isModelLoading = true;
                _hasError = false;
              });
              _initializeModelSilently();
            },
          ),
        ),
      );
      return;
    }

    ref.read(chatProvider.notifier).addMessage(text, 'user');
    _textController.clear();
    _scrollToBottom();
  }

  Future<void> _showClearChatDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Clear Chat History?',
          style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'This will delete all messages and reset the AI context. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ref.read(chatProvider.notifier).startNewChat();
      setState(() {});
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // ✅ ALWAYS show chat UI immediately - no blocking screen!

    final messages = ref.watch(chatProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Mobileshiksha',
          style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear Chat',
            onPressed: _showClearChatDialog,
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyState()
                : _buildMessageList(messages),
          ),
          _buildInputArea(context),
        ],
      ),
    );
  }

  Widget _buildMessageList(List messages) {
    final isGenerating = ref.watch(isGeneratingProvider);

    // Check if the last message is from user (AI is "thinking")
    final isThinking =
        isGenerating && messages.isNotEmpty && messages.last.role == 'user';

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length + (isThinking ? 1 : 0),
      itemBuilder: (context, index) {
        // Show "Thinking..." bubble at the end
        if (isThinking && index == messages.length) {
          return _buildThinkingIndicator(context);
        }

        final message = messages[index];
        final isUser = message.role == 'user';
        return _buildMessageBubble(context, message.content, isUser);
      },
    );
  }

  Widget _buildThinkingIndicator(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BouncingDot(
              color: Theme.of(context).colorScheme.primary,
              delay: 0,
            ),
            const SizedBox(width: 4),
            _BouncingDot(
              color: Theme.of(context).colorScheme.primary,
              delay: 150,
            ),
            const SizedBox(width: 4),
            _BouncingDot(
              color: Theme.of(context).colorScheme.primary,
              delay: 300,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Start a conversation',
            style: GoogleFonts.outfit(
              fontSize: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    String content,
    bool isUser,
  ) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isUser ? const Radius.circular(16) : Radius.zero,
            bottomRight: isUser ? Radius.zero : const Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'AI Tutor',
                    style: GoogleFonts.lexend(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            // ✅ Show bouncing dots for placeholder, otherwise render content
            _buildMessageContent(content, isUser, context),
          ],
        ),
      ),
    );
  }

  /// Helper to render message content or bouncing dots for placeholder
  Widget _buildMessageContent(
    String content,
    bool isUser,
    BuildContext context,
  ) {
    // If assistant is showing placeholder, show progressive thinking indicator
    if (!isUser && content == '...') {
      return _ProgressiveThinkingIndicator(
        color: Theme.of(context).colorScheme.primary,
        textColor: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }

    // Otherwise render normal content
    return isUser
        ? Text(
            content,
            style: GoogleFonts.lexend(
              fontSize: 15.5,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          )
        : MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              // Lexend font - designed for reading accessibility
              // Perfect for students as it reduces visual stress
              p: GoogleFonts.lexend(
                fontSize: 15.5,
                fontWeight: FontWeight.w400,
                height: 1.7, // Generous line height for easy reading
                color: Theme.of(context).colorScheme.onSurface,
                letterSpacing: 0.2,
              ),
              // Bold key terms with accent color
              strong: GoogleFonts.lexend(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF64B5F6) // Light blue for dark mode
                    : const Color(0xFF1565C0), // Deep blue for light mode
              ),
              // Italic for emphasis
              em: GoogleFonts.lexend(
                fontSize: 15.5,
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              // Headings for structure
              h1: GoogleFonts.lexend(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              h2: GoogleFonts.lexend(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              h3: GoogleFonts.lexend(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              // Bullet points - clear and spaced
              listBullet: GoogleFonts.lexend(
                fontSize: 15.5,
                height: 1.6,
                color: Theme.of(context).colorScheme.primary,
              ),
              listIndent: 20,
              // Code blocks with monospace
              code: GoogleFonts.jetBrainsMono(
                fontSize: 13,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withAlpha(180),
                color: Theme.of(context).colorScheme.tertiary,
              ),
              codeblockDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withAlpha(50),
                ),
              ),
              codeblockPadding: const EdgeInsets.all(14),
              // Blockquotes for definitions/important notes
              blockquote: GoogleFonts.lexend(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 4,
                  ),
                ),
              ),
              blockquotePadding: const EdgeInsets.only(
                left: 16,
                top: 8,
                bottom: 8,
              ),
            ),
          );
  }

  Widget _buildInputArea(BuildContext context) {
    final isGenerating = ref.watch(isGeneratingProvider);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              textInputAction:
                  TextInputAction.send, // Change keyboard entry to "Send"
              onSubmitted: (_) => _handleSubmitted(_textController.text),
              // ✅ FIX: Trigger rebuild when text changes so send button updates
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Ask anything...',
                hintStyle: GoogleFonts.inter(),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
            ),
          ),
          // ✅ Dynamic Send/Stop button with visual feedback
          IconButton.filled(
            onPressed: isGenerating
                ? () =>
                      ref.read(chatProvider.notifier).cancelCurrentGeneration()
                : _textController.text.trim().isEmpty
                ? null
                : () => _handleSubmitted(_textController.text),
            icon: isGenerating
                ? const Icon(Icons.stop_rounded, size: 24) // Clear stop icon
                : const Icon(Icons.arrow_upward),
            tooltip: isGenerating ? 'Stop generating' : 'Send message',
            style: IconButton.styleFrom(
              backgroundColor: isGenerating
                  ? Colors
                        .red
                        .shade600 // Red when generating
                  : Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Progressive thinking indicator with time-based status messages
class _ProgressiveThinkingIndicator extends StatefulWidget {
  final Color color;
  final Color textColor;

  const _ProgressiveThinkingIndicator({
    required this.color,
    required this.textColor,
  });

  @override
  State<_ProgressiveThinkingIndicator> createState() =>
      _ProgressiveThinkingIndicatorState();
}

class _ProgressiveThinkingIndicatorState
    extends State<_ProgressiveThinkingIndicator> {
  String _currentMessage = 'Thinking';
  Timer? _timer;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    // Update message every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _elapsedSeconds++;
        if (_elapsedSeconds >= 5) {
          _currentMessage = 'Preparing explanation';
        } else if (_elapsedSeconds >= 2) {
          _currentMessage = 'Understanding context';
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _currentMessage,
          style: GoogleFonts.lexend(
            fontSize: 14,
            fontStyle: FontStyle.italic,
            color: widget.textColor,
          ),
        ),
        const SizedBox(width: 4),
        _BouncingDot(color: widget.color, delay: 0),
        const SizedBox(width: 3),
        _BouncingDot(color: widget.color, delay: 150),
        const SizedBox(width: 3),
        _BouncingDot(color: widget.color, delay: 300),
      ],
    );
  }
}

/// ChatGPT-style bouncing dot indicator
class _BouncingDot extends StatefulWidget {
  final Color color;
  final int delay; // Delay in milliseconds before starting animation

  const _BouncingDot({required this.color, required this.delay});

  @override
  State<_BouncingDot> createState() => _BouncingDotState();
}

class _BouncingDotState extends State<_BouncingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    // Start animation after delay
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) {
        _controller.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, -4 * _animation.value), // Reduced from 8px to 4px
          child: Container(
            width: 3, // Reduced from 8 to 3
            height: 3, // Reduced from 8 to 3
            decoration: BoxDecoration(
              color: widget.color.withValues(
                alpha: 0.7 + 0.3 * _animation.value,
              ),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

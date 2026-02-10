import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/chat_provider.dart';
import '../providers/ui_provider.dart';
import '../widgets/app_drawer.dart';
import 'profile_setup_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _DashedCirclePainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;

  _DashedCirclePainter({
    required this.color,
    this.strokeWidth = 2.0,
    this.gap = 2.0, // Tighter gap for denser dash look
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    double radius = size.width / 2;
    // circumference variable removed as it was unused
    double dashWidth = 6.0; // Longer dashes per user request
    double dashSpace = gap;
    double startAngle = 0;

    while (startAngle < 2 * 3.14159) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(radius, radius), radius: radius),
        startAngle,
        dashWidth / radius,
        false,
        paint,
      );
      startAngle += (dashWidth + dashSpace) / radius;
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
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

    // Check for initial text injection from Home Screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null && args.containsKey('initialText')) {
        _textController.text = args['initialText'];
        setState(() {}); // Update UI to show text
      }
    });
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
      backgroundColor: const Color(0xFFF8F9FA), // Off-white background
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0, // Prevent violet tint overlap
        elevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(
              Icons.menu,
              color: Color(0xFF8B7FD6),
            ), // Violet Menu
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          // New Chat Button
          IconButton(
            onPressed: () {
              ref.read(chatProvider.notifier).startNewChat();
            },
            icon: SizedBox(
              width: 28,
              height: 28,
              child: CustomPaint(
                painter: _DashedCirclePainter(
                  color: const Color(0xFF8B7FD6),
                  strokeWidth: 1.5,
                  gap: 3.0,
                ),
                child: const Center(
                  child: Icon(Icons.add, color: Color(0xFF8B7FD6), size: 16),
                ),
              ),
            ),
            tooltip: 'New Chat',
          ),
          // Profile Button
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const ProfileSetupScreen(isEditMode: true),
              ),
            ),
            icon: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: Color(0xFFE8E5F7),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.person,
                color: Color(0xFF8B7FD6),
                size: 18,
              ),
            ),
            tooltip: 'Profile',
          ),
          const SizedBox(width: 8),
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
          color: const Color(0xFFF3E8FF), // Soft Violet Tint
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BouncingDot(color: const Color(0xFF8B7FD6), delay: 0),
            const SizedBox(width: 4),
            _BouncingDot(color: const Color(0xFF8B7FD6), delay: 150),
            const SizedBox(width: 4),
            _BouncingDot(color: const Color(0xFF8B7FD6), delay: 300),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          const SizedBox(height: 20),

          // Central Sparkle Icon Hero
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFB4A7FA), // Soft light violet (top-left)
                  Color(0xFF9B8DE8), // Mid violet
                  Color(0xFF7C5ED9), // Deep purple (bottom-right)
                ],
                stops: [0.0, 0.4, 1.0],
              ),
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(
                    139,
                    127,
                    214,
                    0.5,
                  ), // Stronger shadow per HTML
                  blurRadius: 40,
                  spreadRadius: -10,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 50,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 32), // 32px gap Logo → Hello
          // Greeting Text
          FutureBuilder<SharedPreferences>(
            future: SharedPreferences.getInstance(),
            builder: (context, snapshot) {
              final name = snapshot.data?.getString('user_name') ?? 'Student';
              return Column(
                children: [
                  Text(
                    'Hello, $name!',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 20, // text-xl per HTML
                      fontWeight: FontWeight.w500, // Medium
                      color: const Color(0xFF94A3B8), // text-muted per HTML
                    ),
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    'How can I help you\ntoday?',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 30, // text-3xl per HTML
                      fontWeight: FontWeight.w700, // Bold
                      color: const Color(0xFF2D2D44), // text-main per HTML
                      height: 1.1, // leading-tight
                      letterSpacing: -0.5, // tracking-tight
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            },
          ),

          Container(
            margin: const EdgeInsets.only(top: 16, bottom: 24),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'I\'m here to help you learn your subjects offline. Choose a shortcut or ask me anything!',
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 15, // text-[15px] per HTML
                color: const Color(0xFF94A3B8), // text-muted per HTML
                height: 1.6, // leading-relaxed
              ),
            ),
          ),

          const SizedBox(height: 48),

          // Suggested Topics (2x2 Grid)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            // Good height, will reduce icon spacing for more text width
            childAspectRatio: 2.0,
            children: [
              _QuickActionCard(
                icon: Icons.school, // Filled mortarboard
                label: 'Homework Help',
                onTap: () {
                  _textController.text = 'Help with Homework: ';
                  _textController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _textController.text.length),
                  );
                },
              ),
              _QuickActionCard(
                icon: Icons.lightbulb, // Filled lightbulb
                label: 'Explain Concept',
                onTap: () {
                  _textController.text = 'Explain a Concept: ';
                  _textController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _textController.text.length),
                  );
                },
              ),
              _QuickActionCard(
                icon: Icons.quiz_outlined, // Outlined quiz per reference
                label: 'Take a Quiz',
                onTap: () {
                  _textController.text = 'Take a Quiz: ';
                  _textController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _textController.text.length),
                  );
                },
              ),
              _QuickActionCard(
                icon: Icons.auto_fix_high, // Filled magic wand
                label: 'Summarize',
                onTap: () {
                  _textController.text = 'Summarize: ';
                  _textController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _textController.text.length),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    String content,
    bool isUser,
  ) {
    if (isUser) {
      // User Message: Right Aligned, White, Rounded-TR-None
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey[100]!),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.zero, // Pointy corner
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: _buildMessageContent(content, isUser, context),
        ),
      );
    } else {
      // AI Message: Row Layout [Avatar + Bubble]
      final isThinking = content == '...';

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // AI Avatar (Outside Bubble)
            Container(
              margin: const EdgeInsets.only(top: 4, right: 12),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFF8B7FD6).withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF8B7FD6).withValues(alpha: 0.2),
                ),
              ),
              child: const Icon(
                Icons.auto_awesome,
                size: 18,
                color: Color(0xFF8B7FD6),
              ),
            ),

            // AI Bubble
            Flexible(
              child: Container(
                padding: isThinking
                    ? const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ) // Small pill padding
                    : const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ), // Normal padding
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: isThinking
                      ? Border.all(color: Colors.grey[200]!)
                      : Border.all(color: Colors.grey[200]!),
                  borderRadius: isThinking
                      ? BorderRadius.circular(999) // Pill shape for thinking
                      : const BorderRadius.only(
                          topLeft: Radius.zero, // Pointy corner
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: _buildMessageContent(content, isUser, context),
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildMessageContent(
    String content,
    bool isUser,
    BuildContext context,
  ) {
    if (!isUser && content == '...') {
      return _ProgressiveThinkingIndicator(
        color: const Color(0xFF8B7FD6),
        textColor: const Color(0xFF8B7FD6), // Violet text for thinking
      );
    }

    final scale = ref.watch(fontSizeProvider);
    final textColor = isUser
        ? const Color(0xFF2D2D44) // Ref: text-text-main
        : const Color(0xFF2D2D44);

    return isUser
        ? Text(
            content,
            style: GoogleFonts.plusJakartaSans(
              fontSize: (15 * scale).toDouble(), // 15px as per ref
              fontWeight: FontWeight.w500,
              height: 1.6, // leading-relaxed
              color: textColor,
            ),
          )
        : MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: GoogleFonts.plusJakartaSans(
                // Base text
                fontSize: (15 * scale).toDouble(),
                fontWeight: FontWeight.w400,
                height: 1.6,
                color: const Color(0xFF2D2D44), // Dark grey/black
              ),
              strong: GoogleFonts.plusJakartaSans(
                // Bold/Strong text
                fontWeight: FontWeight.w700,
                color: const Color(0xFF8B7FD6), // Brand Violet
                fontSize: (15 * scale).toDouble(),
              ),
              listBullet: GoogleFonts.plusJakartaSans(
                // List bullets
                color: const Color(0xFF8B7FD6),
                fontSize: (15 * scale).toDouble(),
                fontWeight: FontWeight.bold,
              ),
              h1: GoogleFonts.plusJakartaSans(
                fontSize: (20 * scale).toDouble(),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF2D2D44),
              ),
              h2: GoogleFonts.plusJakartaSans(
                fontSize: (18 * scale).toDouble(),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF2D2D44),
              ),
            ),
          );
  }

  Widget _buildInputArea(BuildContext context) {
    final isGenerating = ref.watch(isGeneratingProvider);

    return Container(
      // Removed white background and shadow as requested
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Chips Removed
          // Input Area
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56, maxHeight: 150),
              decoration: BoxDecoration(
                color: Colors.white, // White to pop against #F8F9FA bg
                borderRadius: BorderRadius.circular(
                  28,
                ), // Pill shape (half of height)
                border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color.fromRGBO(
                      139,
                      127,
                      214,
                      0.12,
                    ), // Stronger shadow per spec
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Ask me anything...',
                        hintStyle: GoogleFonts.inter(
                          color: const Color(0xFF9CA3AF),
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF1A1A1A),
                      ),
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ),
                  // Send Button - centered vertically
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: IconButton(
                      onPressed: isGenerating
                          ? () => ref
                                .read(chatProvider.notifier)
                                .cancelCurrentGeneration()
                          : _textController.text.trim().isEmpty
                          ? null
                          : () => _handleSubmitted(_textController.text),
                      icon: isGenerating
                          ? const Icon(
                              Icons.stop_circle_outlined,
                              size: 24,
                              color: Colors.red,
                            )
                          : const Icon(Icons.arrow_upward, size: 24),
                      style: IconButton.styleFrom(
                        foregroundColor: const Color(0xFF8B7FD6),
                      ),
                    ),
                  ),
                ],
              ),
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
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
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

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white, // Surface
        borderRadius: BorderRadius.circular(24), // 24px Radius
        border: Border.all(
          color: const Color(0xFFE5E7EB),
          width: 1,
        ), // 1px Subtle Border
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(
              139,
              127,
              214,
              0.12,
            ), // Stronger shadow per spec
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ), // Reduced horizontal padding
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F2FB),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: const Color(0xFF8B7FD6), size: 24),
                ),
                const SizedBox(width: 8), // Reduced gap for more text space
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF2D2D44),
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

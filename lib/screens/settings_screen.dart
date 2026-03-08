import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/chat_provider.dart';
import '../providers/download_provider.dart';

import '../providers/ui_provider.dart'; // For Text Size
import 'profile_setup_screen.dart';
import 'benchmark_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Easter egg: 5-tap counter for benchmark screen
  int _tapCount = 0;
  Timer? _tapTimer;

  String _modelSizeDisplay = 'Calculating...';

  @override
  void initState() {
    super.initState();
    _calculateModelSize();
  }

  Future<void> _calculateModelSize() async {
    try {
      final downloadService = ref.read(modelDownloadServiceProvider);
      final path = await downloadService.getModelPath();
      final file = File(path);
      if (await file.exists()) {
        final sizeBytes = await file.length();
        final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
        if (mounted) {
          setState(() {
            _modelSizeDisplay = '${sizeMb}MB Used';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _modelSizeDisplay = '0MB Used';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelSizeDisplay = 'Unknown Size';
        });
      }
    }
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  void _handleKnowledgeBaseTap() {
    _tapCount++;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(seconds: 2), () {
      _tapCount = 0;
    });
    if (_tapCount >= 5) {
      _tapCount = 0;
      _tapTimer?.cancel();
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BenchmarkScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = ref.watch(fontSizeProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA), // Standard background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Settings',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: const Color(0xFF1A1A1A),
            fontSize: 24,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF1A1A1A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Offline Ready Card — wrapped with GestureDetector for easter egg
            GestureDetector(
              onTap: _handleKnowledgeBaseTap,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF8B7FD6).withValues(alpha: 0.05),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Color(0xFF10B981),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'OFFLINE READY',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF10B981),
                            letterSpacing: 1.0,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3E8FF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.dns_rounded, // Database/cylinder icon
                            color: Color(0xFF8B7FD6),
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Knowledge Base',
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Progress Bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                        value: 1.0,
                        minHeight: 12,
                        backgroundColor: const Color(0xFFF3F4F6),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF8B7FD6),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _modelSizeDisplay,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF8B7FD6),
                          ),
                        ),
                        Text(
                          'Phone Storage',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Your AI tutor lives on your phone. It works perfectly without any internet connection.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: Colors.grey[600],
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),

            // 2. My Profile
            Text(
              'My Profile',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                title: Text(
                  'What should we call you?',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: Colors.grey[500],
                  ),
                ),
                subtitle: FutureBuilder<SharedPreferences>(
                  future: SharedPreferences.getInstance(),
                  builder: (context, snapshot) {
                    final name =
                        snapshot.data?.getString('user_name') ?? 'Student';
                    return Text(
                      name,
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        color: const Color(0xFF1A1A1A),
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
                trailing: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF3E8FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.edit,
                    size: 18,
                    color: Color(0xFF8B7FD6),
                  ),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const ProfileSetupScreen(isEditMode: true),
                    ),
                  ).then((_) {
                    // Force rebuild if needed
                  });
                },
              ),
            ),

            const SizedBox(height: 32),

            // 3. Look & Feel
            Text(
              'Look & Feel',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Text Size',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF1A1A1A),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3E8FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _getFontSizeLabel(fontSize),
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF8B7FD6),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        'Aa',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.grey[400],
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: const Color(0xFFD8D0F2),
                            inactiveTrackColor: const Color(0xFFF3F4F6),
                            thumbColor: const Color(0xFF8B7FD6),
                            overlayColor: const Color(
                              0xFF8B7FD6,
                            ).withValues(alpha: 0.1),
                            trackHeight: 6.0,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 10.0,
                            ),
                          ),
                          child: Slider(
                            value: fontSize,
                            min: 0.8,
                            max: 1.2,
                            divisions: 2,
                            onChanged: (value) {
                              ref
                                  .read(fontSizeProvider.notifier)
                                  .setFontSize(value);
                            },
                          ),
                        ),
                      ),
                      Text(
                        'Aa',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          color: const Color(0xFF1A1A1A),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 48),

            // 4. Destructive Action
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () => _showClearDataDialog(context, ref),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(
                    color: Color(0xFFFFE4E4),
                    width: 1.5,
                  ), // Light Red Border
                  backgroundColor: const Color(0xFFFFF1F2), // Very Light Red
                  foregroundColor: const Color(0xFFE11D48), // Deep Red Text
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: const Icon(Icons.history_toggle_off),
                label: const Text('Clear Chat History'),
              ),
            ),

            const SizedBox(height: 24),
            Center(
              child: Text(
                'Shiksha AI',
                style: GoogleFonts.inter(fontSize: 12, color: Colors.grey[400]),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _getFontSizeLabel(double size) {
    if (size <= 0.8) return 'Small';
    if (size >= 1.2) return 'Large';
    return 'Medium';
  }

  void _showClearDataDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Chat History?'),
        content: const Text(
          'This will permanently delete all your conversation history. Your Knowledge Base (900MB) will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await ref.read(chatProvider.notifier).clearAllChats();
              if (context.mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Chat history cleared')),
                );
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text('Clear History'),
          ),
        ],
      ),
    );
  }
}

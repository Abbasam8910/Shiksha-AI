import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../providers/chat_provider.dart';
import '../providers/theme_provider.dart';
import '../models/chat_session.dart';
import '../screens/settings_screen.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(chatSessionsProvider);
    final currentSessionId = ref.watch(currentSessionIdProvider);
    final themeMode = ref.watch(themeProvider);

    // Group sessions by date
    final now = DateTime.now();
    final today = <ChatSession>[];
    final yesterday = <ChatSession>[];
    final previous7Days = <ChatSession>[];
    final older = <ChatSession>[];

    for (var session in sessions) {
      final diff = now.difference(session.lastUpdated).inDays;
      if (diff == 0 && session.lastUpdated.day == now.day) {
        today.add(session);
      } else if (diff == 1 ||
          (diff == 0 && session.lastUpdated.day != now.day)) {
        yesterday.add(session);
      } else if (diff <= 7) {
        previous7Days.add(session);
      } else {
        older.add(session);
      }
    }

    return Drawer(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // Header / New Chat Button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  ref.read(chatProvider.notifier).startNewChat();
                  Navigator.pop(context); // Close drawer
                },
                icon: const Icon(Icons.add),
                label: const Text('New Chat'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ),

          // Chat History List
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (today.isNotEmpty)
                  _buildSection(context, 'Today', today, currentSessionId, ref),
                if (yesterday.isNotEmpty)
                  _buildSection(
                    context,
                    'Yesterday',
                    yesterday,
                    currentSessionId,
                    ref,
                  ),
                if (previous7Days.isNotEmpty)
                  _buildSection(
                    context,
                    'Previous 7 Days',
                    previous7Days,
                    currentSessionId,
                    ref,
                  ),
                if (older.isNotEmpty)
                  _buildSection(context, 'Older', older, currentSessionId, ref),
              ],
            ),
          ),

          // Footer / Settings
          const Divider(),
          ListTile(
            leading: Icon(
              themeMode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode,
            ),
            title: Text(
              themeMode == ThemeMode.dark ? 'Light Mode' : 'Dark Mode',
            ),
            onTap: () {
              ref.read(themeProvider.notifier).toggleTheme();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context); // Close drawer first
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<ChatSession> sessions,
    String? currentId,
    WidgetRef ref,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        ...sessions.map(
          (session) =>
              _buildSessionTile(context, session, currentId == session.id, ref),
        ),
      ],
    );
  }

  Widget _buildSessionTile(
    BuildContext context,
    ChatSession session,
    bool isSelected,
    WidgetRef ref,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Dismissible(
        key: Key(session.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.delete,
            color: Theme.of(context).colorScheme.onError,
          ),
        ),
        confirmDismiss: (direction) async {
          return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete Chat'),
              content: const Text('Are you sure you want to delete this chat?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
        },
        onDismissed: (direction) {
          ref.read(chatProvider.notifier).deleteSession(session.id);
        },
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          selected: isSelected,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          title: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          onTap: () {
            ref.read(chatProvider.notifier).loadSession(session.id);
            Navigator.pop(context);
          },
        ),
      ),
    );
  }
}

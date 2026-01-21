import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/chat_provider.dart';
import '../widgets/app_drawer.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(chatSessionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Mobileshiksha',
          style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              ref.read(chatProvider.notifier).startNewChat();
              Navigator.pushNamed(context, '/chat');
            },
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: sessions.isEmpty
          ? _buildEmptyState(context, ref)
          : ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                return ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${session.messages.length} messages',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: Text(
                    _formatDate(session.lastUpdated),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () {
                    ref.read(chatProvider.notifier).loadSession(session.id);
                    Navigator.pushNamed(context, '/chat');
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          ref.read(chatProvider.notifier).startNewChat();
          Navigator.pushNamed(context, '/chat');
        },
        icon: const Icon(Icons.add),
        label: const Text('New Chat'),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
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
            'No chat history',
            style: GoogleFonts.outfit(
              fontSize: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              ref.read(chatProvider.notifier).startNewChat();
              Navigator.pushNamed(context, '/chat');
            },
            icon: const Icon(Icons.add),
            label: const Text('Start New Chat'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}

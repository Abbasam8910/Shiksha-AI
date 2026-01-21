import 'package:hive/hive.dart';
import 'chat_message.dart';

part 'chat_session.g.dart';

@HiveType(typeId: 1)
class ChatSession extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final List<ChatMessage> messages;

  @HiveField(3)
  final DateTime lastUpdated;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.lastUpdated,
  });
}

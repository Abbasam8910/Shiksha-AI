import 'package:flutter/material.dart';
import 'dart:async'; // Required for runZonedGuarded
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'models/chat_message.dart';
import 'models/chat_session.dart';
import 'providers/chat_provider.dart';
import 'providers/download_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/model_download_screen.dart';

import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';

void main() {
  // ✅ CRITICAL: Wrap ENTIRE main in runZonedGuarded to fix Zone mismatch
  runZonedGuarded(
    () async {
      // ✅ STEP 1: MUST be called FIRST, before anything else
      WidgetsFlutterBinding.ensureInitialized();

      // ✅ STEP 2: Load native libraries (before runApp)
      if (Platform.isAndroid) {
        try {
          DynamicLibrary.open('libomp.so');
          DynamicLibrary.open('libggml-base.so');
          DynamicLibrary.open('libggml-cpu.so');
          DynamicLibrary.open('libggml.so');
          DynamicLibrary.open('libllama.so');
          if (kDebugMode) print('✅ Native libraries loaded successfully');
        } catch (e) {
          if (kDebugMode) print('❌ Error loading native libraries: $e');
        }
      }

      // ✅ STEP 3: Initialize Hive (same zone as runApp now)
      await Hive.initFlutter();
      Hive.registerAdapter(ChatMessageAdapter());
      Hive.registerAdapter(ChatSessionAdapter());
      final chatBox = await Hive.openBox<ChatSession>('chat_sessions');

      // ✅ STEP 4: Set up global error handlers
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('❌ [FLUTTER ERROR]: ${details.exception}');
        if (details.stack != null) debugPrint('Stack: ${details.stack}');
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('❌ [PLATFORM ERROR]: $error\n$stack');
        return true;
      };

      // ✅ STEP 5: Run app (now in same zone as binding initialization)
      runApp(
        ProviderScope(
          overrides: [chatBoxProvider.overrideWithValue(chatBox)],
          child: const MyApp(),
        ),
      );
    },
    (error, stack) {
      debugPrint('❌ [ZONED ERROR]: $error\n$stack');
    },
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final llmService = ref.read(llmServiceProvider);

    switch (state) {
      case AppLifecycleState.paused:
        // 🟡 Backgrounded: Cancel active generation but KEEP model in RAM
        // This ensures instant resume when user returns
        debugPrint('📱 [LIFECYCLE] App paused - Cancelling active generation');
        llmService.cancelGeneration();
        break;

      case AppLifecycleState.inactive:
        // ⚠️ NOTE: 'inactive' triggers when keyboard opens/closes
        // DO NOT cancel generation here - it's not a true background event
        debugPrint('📱 [LIFECYCLE] App inactive (keyboard or transition)');
        // Removed: llmService.cancelGeneration() - was causing false cancels
        break;

      case AppLifecycleState.detached:
        // 🔴 Closed/Killed: Unload model to free RAM
        debugPrint('📱 [LIFECYCLE] App detached - Unloading model');
        llmService.unloadModel();
        break;

      case AppLifecycleState.resumed:
        debugPrint('📱 [LIFECYCLE] App resumed');
        break;

      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      title: 'Mobileshiksha',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A67E), // OpenAI-ish green
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A67E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
      ),
      home: Consumer(
        builder: (context, ref, _) {
          final downloadService = ref.watch(modelDownloadServiceProvider);

          return FutureBuilder<bool>(
            future: downloadService.isModelDownloaded(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              // If model is downloaded, go directly to chat
              if (snapshot.data == true) {
                return const ChatScreen();
              }

              // Otherwise show onboarding
              return const OnboardingScreen();
            },
          );
        },
      ),
      routes: {
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const HomeScreen(),
        '/chat': (context) => const ChatScreen(),
        '/download': (context) => const ModelDownloadScreen(),
      },
    );
  }
}

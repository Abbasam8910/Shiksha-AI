import 'package:flutter/material.dart';
import 'dart:async'; // Required for runZonedGuarded
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/chat_message.dart';
import 'models/chat_session.dart';
import 'providers/chat_provider.dart';
import 'providers/download_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/onboarding_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/model_download_screen.dart';
import 'screens/profile_setup_screen.dart';

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
      title: 'Shiksha AI',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        physics: const BouncingScrollPhysics(),
      ),
      themeMode: themeMode,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8F9FA), // Off-White
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF8B7FD6), // Light Violet
          onPrimary: Colors.white,
          surface: Color(0xFFF8F9FA), // Off-White
          onSurface: Color(0xFF1A1A1A), // Near Black (Primary Heading)
          onSurfaceVariant: Color(0xFF4A4A4A), // Dark Grey (Body)
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme().apply(
          bodyColor: const Color(0xFF4A4A4A),
          displayColor: const Color(0xFF1A1A1A),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF8B7FD6),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(
            0xFF8B7FD6,
          ), // Keep primary mostly same or adjust for dark
          onPrimary: Colors.white,
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
          onSurfaceVariant: Color(0xFFB0B0B0),
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF8B7FD6),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      home: Consumer(
        builder: (context, ref, _) {
          final downloadService = ref.watch(modelDownloadServiceProvider);

          // Helper to check state
          Future<String> checkInitialRoute() async {
            final isDownloaded = await downloadService.isModelDownloaded();
            if (!isDownloaded) return '/onboarding';

            final prefs = await SharedPreferences.getInstance();
            final isProfileComplete =
                prefs.getBool('is_profile_completed') ?? false;
            if (!isProfileComplete) return '/profile_setup';

            return '/home'; // Or /chat depending on preference
          }

          return FutureBuilder<String>(
            future: checkInitialRoute(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              final route = snapshot.data ?? '/onboarding';

              if (route == '/home') {
                return const ChatScreen(); // Updated to new Home
              }
              if (route == '/profile_setup') return const ProfileSetupScreen();
              return const OnboardingScreen();
            },
          );
        },
      ),
      routes: {
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const ChatScreen(),
        '/chat': (context) => const ChatScreen(),
        '/download': (context) => const ModelDownloadScreen(),
        '/profile_setup': (context) => const ProfileSetupScreen(),
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/download_provider.dart';

class ModelDownloadScreen extends ConsumerStatefulWidget {
  const ModelDownloadScreen({super.key});

  @override
  ConsumerState<ModelDownloadScreen> createState() =>
      _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends ConsumerState<ModelDownloadScreen> {
  @override
  void initState() {
    super.initState();
    // Start download automatically when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(downloadControllerProvider.notifier).startDownload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(downloadProgressProvider);
    final isDownloading = ref.watch(isDownloadingProvider);
    final error = ref.watch(downloadErrorProvider);
    final isReady = ref.watch(isModelReadyProvider);

    // Navigate to Home if ready and not downloading (and no error)
    if (isReady && !isDownloading && error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/home');
      });
    }

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.download_rounded,
              size: 80,
              color: Colors.deepPurple,
            ),
            const SizedBox(height: 32),
            Text(
              'Downloading Educational Resources',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Setting up your offline AI tutor.\nThis may take a few minutes.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 48),
            if (error != null) ...[
              Text(
                'Error: $error',
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  ref.read(downloadControllerProvider.notifier).startDownload();
                },
                child: const Text('Retry'),
              ),
            ] else ...[
              LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                borderRadius: BorderRadius.circular(5),
              ),
              const SizedBox(height: 16),
              Text(
                '${(progress * 100).toStringAsFixed(1)}%',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

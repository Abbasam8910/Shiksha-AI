import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/model_download_service.dart';

final modelDownloadServiceProvider = Provider((ref) => ModelDownloadService());

final downloadProgressProvider = StateProvider<double>((ref) => 0.0);
final isDownloadingProvider = StateProvider<bool>((ref) => false);
final downloadErrorProvider = StateProvider<String?>((ref) => null);
final isModelReadyProvider = StateProvider<bool>((ref) => false);

class DownloadNotifier extends StateNotifier<void> {
  final ModelDownloadService _service;
  final Ref _ref;

  DownloadNotifier(this._service, this._ref) : super(null) {
    checkModelStatus();
  }

  Future<void> checkModelStatus() async {
    final exists = await _service.isModelDownloaded();
    _ref.read(isModelReadyProvider.notifier).state = exists;
  }

  Future<void> startDownload() async {
    // Check if already downloaded
    if (await _service.isModelDownloaded()) {
      _ref.read(isModelReadyProvider.notifier).state = true;
      return;
    }

    try {
      _ref.read(isDownloadingProvider.notifier).state = true;
      _ref.read(downloadErrorProvider.notifier).state = null;
      _ref.read(downloadProgressProvider.notifier).state = 0.0;

      await _service.downloadModel(
        onProgress: (received, total) {
          if (total != -1) {
            final progress = received / total;
            _ref.read(downloadProgressProvider.notifier).state = progress;
          }
        },
      );

      _ref.read(isModelReadyProvider.notifier).state = true;
    } catch (e) {
      _ref.read(downloadErrorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(isDownloadingProvider.notifier).state = false;
    }
  }

  void cancelDownload() {
    _service.cancelDownload();
    _ref.read(isDownloadingProvider.notifier).state = false;
    _ref.read(downloadProgressProvider.notifier).state = 0.0;
  }
}

final downloadControllerProvider =
    StateNotifierProvider<DownloadNotifier, void>((ref) {
      final service = ref.watch(modelDownloadServiceProvider);
      return DownloadNotifier(service, ref);
    });

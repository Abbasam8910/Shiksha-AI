import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ModelDownloadService {
  final Dio _dio = Dio();
  CancelToken? _cancelToken;

  // ✅ USING BASE QWEN MODEL (proven to work in old code)
  static const String modelUrl =
      'https://huggingface.co/abbas2363/sample/resolve/main/qwen.gguf';
  static const String modelFileName = 'qwen.gguf';

  // File size validation
  static const int _minModelSize = 10 * 1024 * 1024; // 10MB minimum

  Future<String> getModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${dir.path}/model');
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }
    return '${modelDir.path}/$modelFileName';
  }

  Future<bool> isModelDownloaded() async {
    final prefs = await SharedPreferences.getInstance();
    final flag = prefs.getBool('model_downloaded_v1') ?? false;

    if (!flag) return false;

    final path = await getModelPath();
    final file = File(path);

    if (await file.exists()) {
      final fileSize = await file.length();
      return fileSize >= _minModelSize;
    }
    return false;
  }

  Future<void> downloadModel({
    required Function(int received, int total) onProgress,
  }) async {
    try {
      final path = await getModelPath();
      _cancelToken = CancelToken();

      await _dio.download(
        modelUrl,
        path,
        onReceiveProgress: onProgress,
        cancelToken: _cancelToken,
        deleteOnError: true,
      );

      // Validate file size
      final file = File(path);
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize < _minModelSize) {
          await file.delete();
          throw Exception('Downloaded file is too small. Please try again.');
        }
      }

      // Mark as downloaded
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('model_downloaded_v1', true);
    } catch (e) {
      throw Exception('Failed to download model: $e');
    }
  }

  Future<void> clearModel() async {
    final path = await getModelPath();
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('model_downloaded_v1', false);
  }

  void cancelDownload() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }
}

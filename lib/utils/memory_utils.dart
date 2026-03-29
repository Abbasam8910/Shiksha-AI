import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/device_config_service.dart';

class MemoryUtils {
  // model locked size + inference buffer
  static const int modelLockedSizeMb = 1040; // full GGUF in RAM
  static const int inferenceBufferMb = 300;  // KV cache + compute
  static const int mlockMinFreeMb = modelLockedSizeMb + inferenceBufferMb; // = 1340MB

  /// Determines if mlock should be used based on tier and available RAM.
  /// Must be called BEFORE model load to get accurate free RAM reading.
  static Future<bool> shouldUseMlock(ModelConfig config) async {
    // Efficiency Mode always uses mmap (+ warmup) to stay safe on low RAM
    if (config.tierName == 'Efficiency Mode') return false;
    final availableMb = await readMemAvailableMb();
    if (kDebugMode) {
      print('\u{1F512} mlock check: ${availableMb}MB available, need ${mlockMinFreeMb}MB');
    }
    return availableMb > mlockMinFreeMb;
  }

  /// Reads MemAvailable from /proc/meminfo in MB.
  static Future<int> readMemAvailableMb() async {
    try {
      final memFile = File('/proc/meminfo');
      if (!await memFile.exists()) return 0;
      final lines = await memFile.readAsLines();
      for (final line in lines) {
        if (line.startsWith('MemAvailable')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            return (int.tryParse(parts[1]) ?? 0) ~/ 1024;
          }
        }
      }
    } catch (_) {}
    return 0;
  }
}

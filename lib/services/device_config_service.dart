import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Defines the capabilities for different hardware tiers
class ModelConfig {
  final String tierName; // e.g., "High Performance"
  final int contextSize; // nCtx (e.g., 2048 vs 4096)
  final int historyLimit; // keepRecentPairs (e.g., 3 vs 10)
  final int maxTokens; // nPredict (e.g., 256 vs 1024)
  final int threads; // nThreads (Usually 4 for all, maybe 6 for ultra-high)
  final int
  nGpuLayers; // GPU Acceleration Layers (Currently 0 - CPU-only binaries)
  final int batchSize; // nBatch - Prefill batch size for prompt processing
  final bool enableSmartContext; // Use silent injection?
  final String systemPrompt; // Dynamic system prompt per tier

  const ModelConfig({
    required this.tierName,
    required this.contextSize,
    required this.historyLimit,
    required this.maxTokens,
    this.threads = 4,
    this.nGpuLayers = 0,
    this.batchSize = 512,
    this.enableSmartContext = true,
    required this.systemPrompt,
  });

  // Utility to create a modified copy of config
  ModelConfig copyWith({
    String? tierName,
    int? contextSize,
    int? historyLimit,
    int? maxTokens,
    int? threads,
    int? nGpuLayers,
    int? batchSize,
    bool? enableSmartContext,
    String? systemPrompt,
  }) {
    return ModelConfig(
      tierName: tierName ?? this.tierName,
      contextSize: contextSize ?? this.contextSize,
      historyLimit: historyLimit ?? this.historyLimit,
      maxTokens: maxTokens ?? this.maxTokens,
      threads: threads ?? this.threads,
      nGpuLayers: nGpuLayers ?? this.nGpuLayers,
      batchSize: batchSize ?? this.batchSize,
      enableSmartContext: enableSmartContext ?? this.enableSmartContext,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }

  // 🛡️ TIER 1: Low End (<4GB RAM) - Smart efficiency + LaTeX
  // Default short, expands for detailed requests
  factory ModelConfig.lowSpec() {
    return const ModelConfig(
      tierName: 'Efficiency Mode',
      contextSize: 2048,
      historyLimit: 3,
      maxTokens: 256,
      threads: 4,
      nGpuLayers: 0, // CPU-only: No GPU backend compiled in binaries
      batchSize: 512, // Conservative batch for memory safety
      enableSmartContext: true,
      systemPrompt: '''You are Shiksha, a direct student tutor.
Task: Answer the user's question immediately.
Rules:
1. Start directly with the answer. No greetings.
2. **Bold** the most important keywords.
3. For math: Use plain text like x^2 or a²+b²=c². For chemistry: Use subscripts like H₂O, CO₂, C₂H₅OH.
4. Default Behavior: Keep answers short (1-2 sentences).
5. Exception: If the user asks for "detail" or "process", provide a full bulleted list.
6. If you do not know, strictly say "I am not sure."''',
    );
  }

  // ⚖️ TIER 2: Mid Range (4GB - 8GB RAM) - Friendly + LaTeX
  // Explains so a 12-year-old can understand
  factory ModelConfig.midSpec() {
    return const ModelConfig(
      tierName: 'Balanced Mode',
      contextSize: 2048,
      historyLimit: 6,
      maxTokens: 384,
      threads: 4,
      nGpuLayers: 0, // CPU-only: No GPU backend compiled in binaries
      batchSize: 1024, // Higher batch for faster prefill on mid-range CPUs
      enableSmartContext: true,
      systemPrompt: '''You are Shiksha, a friendly student tutor.
Task: Explain concepts so a 12-year-old can understand.
Guidelines:
1. Use simple English only. Avoid academic jargon.
2. **Bold** core terms for easy reading.
3. For math: Write like x² + y² = r². For chemistry: Use subscripts like H₂O, NaCl, C₆H₁₂O₆.
4. Length Control:
   - For simple questions ("What is..."): Keep it to one short paragraph.
   - For detailed requests ("Explain...", "How to..."): Use a step-by-step numbered list.
5. Constraint: If you are unsure, strictly say "I am not sure."''',
    );
  }

  // 🚀 TIER 3: High End (>8GB RAM) - Adaptive: concise OR detailed
  // Uses template only when user asks for explanation
  factory ModelConfig.highSpec() {
    return const ModelConfig(
      tierName: 'Performance Mode',
      contextSize: 4096,
      historyLimit: 10,
      maxTokens: 512,
      threads: 4,
      nGpuLayers:
          0, // CPU-only: Recompile with Vulkan to enable GPU acceleration
      batchSize: 2048, // Max batch for flagship CPUs - fastest prefill
      enableSmartContext: true,
      systemPrompt: '''You are Shiksha, a friendly expert tutor.
Task: Answer questions clearly and concisely.
Formatting: For math use x² or a²+b². For chemistry use subscripts: H₂O, CO₂, C₂H₅OH.

Guidelines:
1. For simple questions ("What is...", "Define..."): Give a **short 1-2 sentence answer**. Bold the key term.
2. For detailed questions ("Explain...", "How does...", "Why..."): Use this structure:
   - **Definition**: One sentence.
   - **Explanation**: 2-3 sentences.
   - **Example**: One real-world example.
3. Only add an **Analogy** if the concept is complex (like physics or chemistry).

Constraint: Say "I am not sure" if you don't know.''',
    );
  }
}

class DeviceProfiler {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static final Battery _battery = Battery();

  static Future<ModelConfig> getBestConfig() async {
    try {
      // 1. BATTERY CHECK - Force Efficiency Mode if battery is low
      try {
        final batteryLevel = await _battery.batteryLevel;
        if (batteryLevel < 20) {
          debugPrint(
            '🪫 Low Battery ($batteryLevel%). Forcing Efficiency Mode.',
          );
          return ModelConfig.lowSpec();
        }
      } catch (e) {
        debugPrint('⚠️ Battery check failed: $e');
      }

      // 2. RAM DETECTION
      final config = await _detectDeviceTier();

      // 3. APPLY DYNAMIC THREAD COUNT
      final optimalThreads = _getOptimalThreads();
      return config.copyWith(threads: optimalThreads);
    } catch (e) {
      debugPrint('⚠️ Failed to profile device, defaulting to Low Spec: $e');
      return ModelConfig.lowSpec();
    }
  }

  // 🖥️ Dynamic CPU thread detection
  static int _getOptimalThreads() {
    try {
      final cpuCores = Platform.numberOfProcessors;
      debugPrint('🖥️ CPU cores detected: $cpuCores');

      // Use 75% of available cores, minimum 4, maximum 8
      final optimalThreads = (cpuCores * 0.75).round().clamp(4, 8);
      debugPrint('🧵 Using $optimalThreads threads (from $cpuCores cores)');
      return optimalThreads;
    } catch (e) {
      debugPrint('! Failed to detect CPU cores: $e, defaulting to 4 threads');
      return 4; // Safe fallback
    }
  }

  // 📱 Device tier detection based on RAM
  static Future<ModelConfig> _detectDeviceTier() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;

        // RAM detection with multiple fallback strategies
        int totalBytes = 0;

        // Strategy 1: Try device_info_plus data map
        final rawMemory = androidInfo.data['totalMemory'];
        debugPrint(
          '📱 Raw Memory from data map: $rawMemory (type: ${rawMemory?.runtimeType})',
        );

        if (rawMemory is int && rawMemory > 0) {
          totalBytes = rawMemory;
        } else if (rawMemory is double && rawMemory > 0) {
          totalBytes = rawMemory.toInt();
        }

        // Strategy 2: Fallback to /proc/meminfo (Linux standard)
        if (totalBytes <= 0) {
          debugPrint('⚠️ Data map failed, trying /proc/meminfo fallback...');
          try {
            final memInfoFile = File('/proc/meminfo');
            if (await memInfoFile.exists()) {
              final lines = await memInfoFile.readAsLines();
              for (var line in lines) {
                if (line.startsWith('MemTotal:')) {
                  // Format: "MemTotal:        5864580 kB"
                  final parts = line.split(RegExp(r'\s+'));
                  if (parts.length >= 2) {
                    final kb = int.tryParse(parts[1]) ?? 0;
                    totalBytes = kb * 1024; // Convert KB to bytes
                    debugPrint('📱 /proc/meminfo MemTotal: $kb KB');
                  }
                  break;
                }
              }
            }
          } catch (e) {
            debugPrint('⚠️ /proc/meminfo read failed: $e');
          }
        }

        // Convert to GB using explicit double division
        final double totalRamGb =
            totalBytes.toDouble() / (1024.0 * 1024.0 * 1024.0);

        debugPrint(
          '📱 Device RAM: ${totalRamGb.toStringAsFixed(2)} GB ($totalBytes bytes)',
        );

        // LOWERED THRESHOLDS for flagship device detection:
        // - 8GB phones report ~7.1-7.4GB usable → trigger Performance Mode
        // - 6GB phones report ~5.4-5.8GB usable → trigger Balanced Mode
        if (totalRamGb >= 6.5) {
          debugPrint('✅ Performance Mode activated (≥6.5GB detected)');
          return ModelConfig.highSpec();
        } else if (totalRamGb >= 5.2) {
          return ModelConfig.midSpec();
        } else {
          return ModelConfig.lowSpec();
        }
      }

      // iOS or other platforms - default to balanced mode
      return ModelConfig.midSpec();
    } catch (e) {
      debugPrint('⚠️ Failed to detect device tier: $e');
      return ModelConfig.lowSpec();
    }
  }

  /// Checks if the device has enough free memory to load the model safely.
  /// Returns false ONLY if we are certain memory is critical.
  static Future<bool> hasEnoughMemory() async {
    try {
      if (Platform.isAndroid) {
        // 🔧 FIX: Read /proc/meminfo directly (most reliable method)
        try {
          final memInfoFile = File('/proc/meminfo');
          if (await memInfoFile.exists()) {
            final lines = await memInfoFile.readAsLines();

            int totalKb = 0;
            int availableKb = 0;

            for (var line in lines) {
              if (line.startsWith('MemTotal:')) {
                // Format: "MemTotal:        5864580 kB"
                final parts = line.split(RegExp(r'\s+'));
                if (parts.length >= 2) {
                  totalKb = int.tryParse(parts[1]) ?? 0;
                }
              } else if (line.startsWith('MemAvailable:')) {
                // Format: "MemAvailable:    2345678 kB"
                final parts = line.split(RegExp(r'\s+'));
                if (parts.length >= 2) {
                  availableKb = int.tryParse(parts[1]) ?? 0;
                }
              }

              // Exit early if both values found
              if (totalKb > 0 && availableKb > 0) break;
            }

            // Convert KB to GB
            final totalGb = totalKb / (1024 * 1024);
            final availableGb = availableKb / (1024 * 1024);

            // Need at least 500MB free
            const requiredGb = 0.5;
            final hasEnough = availableGb >= requiredGb;

            debugPrint(
              '💾 Memory Check: ${availableGb.toStringAsFixed(2)}GB available '
              '(Total: ${totalGb.toStringAsFixed(2)}GB). Need ${requiredGb}GB. Result: $hasEnough',
            );

            return hasEnough;
          }
        } catch (e) {
          debugPrint('⚠️ /proc/meminfo read failed: $e');
        }

        // 🛡️ FALLBACK: If meminfo fails, assume we have enough memory
        // (Better to try and fail than block unnecessarily)
        debugPrint('⚠️ Memory check failed, using optimistic fallback (true)');
        return true;
      }

      // iOS manages memory automatically
      return true;
    } catch (e) {
      debugPrint('⚠️ Memory check exception: $e');
      return true; // Optimistic fallback
    }
  }
}

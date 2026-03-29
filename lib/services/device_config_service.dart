import 'dart:io';
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
      contextSize: 1024,
      historyLimit: 3,
      maxTokens: 150,
      threads: 4,
      nGpuLayers: 0, // CPU-only: No GPU backend compiled in binaries
      batchSize: 256, // FIX 2: Conservative batch for memory safety (was 512)
      enableSmartContext: true,
      // OPTIMIZED PROMPT: < 40 tokens for fast start
      systemPrompt:
          '''You are Shiksha AI, a helpful tutor. Explain simply in easy English.
RULES:
1. Use **Bold** for key terms.
2. Use Bullet points for lists.
3. Keep answers short (3-4 sentences).
4. For Math/Science, show steps safely.
Do not hallucinate.''',
    );
  }

  // ⚖️ TIER 2: Mid Range (4GB - 8GB RAM) - Friendly + LaTeX
  // Explains so a 12-year-old can understand
  factory ModelConfig.midSpec() {
    return const ModelConfig(
      tierName: 'Balanced Mode',
      contextSize: 2048,
      historyLimit: 6,
      maxTokens: 200,
      threads: 4,
      nGpuLayers: 0, // CPU-only: No GPU backend compiled in binaries
      batchSize: 512, // FIX 2: Balanced batch for mid-range CPUs (was 1024)
      enableSmartContext: true,
      // OPTIMIZED PROMPT: Focuses on structure and tone
      systemPrompt:
          '''You are Shiksha AI, a friendly student tutor. Explain concepts clearly using simple language.
FORMATTING RULES:
- Use **Bold** for important concepts.
- ALWAYS use Bullet points for steps or lists.
- Use new lines to separate ideas.
- For Math: Show the formula, then the steps.
- Start concise; only provide long details if explicitly asked.''',
    );
  }

  // 🚀 TIER 3: High End (>8GB RAM) - Adaptive: concise OR detailed
  // Uses template only when user asks for explanation
  factory ModelConfig.highSpec() {
    return const ModelConfig(
      tierName: 'Performance Mode',
      contextSize: 4096,
      historyLimit: 10,
      maxTokens: 300,
      threads: 4,
      nGpuLayers:
          0, // CPU-only: Recompile with Vulkan to enable GPU acceleration
      batchSize: 512, // FIX 2: Capped for mobile — no benefit from >512 in single-user (was 2048)
      enableSmartContext: true,
      // OPTIMIZED PROMPT: detailed instructions without wasting tokens on examples
      systemPrompt:
          '''You are Shiksha AI, an expert tutor. Provide comprehensive but easy-to-understand explanations.
GUIDELINES:
1. **Format**: Use Headers, **Bold terms**, and Bullet points to break up text.
2. **Math/Science**: Define the formula, show the substitution, then solve step-by-step.
3. **Tone**: Encouraging and academic but simple.
4. **Length**: Adapt to the user. Give a summary first, then details if the topic is complex.''',
    );
  }
}

class DeviceProfiler {
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

      // 2. READ /proc/cpuinfo ONCE — shared by chip scorer and thread resolver
      // FIX 1 & FIX 3: Single file read, passed to both helpers
      String cpuinfoContent = '';
      if (Platform.isAndroid) {
        try {
          final cpuFile = File('/proc/cpuinfo');
          if (await cpuFile.exists()) {
            cpuinfoContent = (await cpuFile.readAsString()).toLowerCase();
          }
        } catch (e) {
          debugPrint('⚠️ Failed to read /proc/cpuinfo: $e');
        }
      }

      // 3. RAM + CHIP DETECTION (FIX 1: chip score gates tier assignment)
      final config = await _detectDeviceTier(cpuinfoContent);

      // 4. APPLY DYNAMIC THREAD COUNT (FIX 3: chipset-aware)
      final optimalThreads = await _getOptimalThreads(cpuinfoContent);
      return config.copyWith(threads: optimalThreads);
    } catch (e) {
      debugPrint('⚠️ Failed to profile device, defaulting to Low Spec: $e');
      return ModelConfig.lowSpec();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FIX 1: Chip performance scoring alongside RAM check
  // ═══════════════════════════════════════════════════════════════════════

  /// Returns chip generation score from /proc/cpuinfo content.
  /// 2 = flagship/upper-mid, 1 = mid-range, 0 = budget/old.
  /// Unknown chips default to 1 (mid) — safe conservative default.
  static Future<int> _getChipScoreAsync() async {
    int maxFrequencyMHz = 0;
    int perfCoreCount = 0;
    try {
      final cpuDir = Directory('/sys/devices/system/cpu');
      if (await cpuDir.exists()) {
        final entities = await cpuDir.list().toList();
        for (final entity in entities) {
          if (!RegExp(r'cpu\d+$').hasMatch(entity.path)) continue;
          final freqFile = File('${entity.path}/cpufreq/cpuinfo_max_freq');
          if (await freqFile.exists()) {
            final freq = int.tryParse((await freqFile.readAsString()).trim()) ?? 0;
            if (freq > maxFrequencyMHz) maxFrequencyMHz = freq;
            if (freq >= 2000000) perfCoreCount++;
          }
        }
      }
    } catch (_) {}
    
    maxFrequencyMHz = maxFrequencyMHz ~/ 1000; // Khz to MHz

    // Flagship: 4+ perf cores AND clock > 2400MHz (catches 7 Gen 3, 8 Gen 1, 8+ Gen 1)
    if (perfCoreCount >= 4 && maxFrequencyMHz > 2400) return 2;
    // Mid: any perf core above 2000MHz
    if (maxFrequencyMHz > 2000) return 1;
    // Budget: everything else
    return 0;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FIX 3: Chipset-aware thread count with dynamic core counting fallback
  // ═══════════════════════════════════════════════════════════════════════

  /// 🖥️ Optimal thread count — chipset-aware for ARM processors.
  /// Uses codename list for known chips, then falls back to dynamic
  /// performance core counting via /sys/devices/system/cpu/.
  static Future<int> _getOptimalThreads(String cpuinfoContent) async {
    try {
      final cpuCores = Platform.numberOfProcessors;
      debugPrint('🖥️ CPU cores detected: $cpuCores');

      // For desktop (Windows/Linux/macOS), use 75% of cores
      if (!(Platform.isAndroid || Platform.isIOS)) {
        final optimalThreads = (cpuCores * 0.75).round().clamp(4, 8);
        debugPrint('🧵 Using $optimalThreads threads (from $cpuCores cores)');
        return optimalThreads;
      }

      // ── ARM mobile path ──────────────────────────────────────────────

      // Strategy 1: Known chips with exactly 2 performance cores
      // Using 4 threads on these causes A55 spillover and
      // reduces TPS by ~30% due to memory bandwidth contention.
      const twoCorePerfChips = [
        'sm6150',   // Snapdragon 675
        'trinket',  // Snapdragon 730G / 732G
        'bengal',   // Snapdragon 662 / 665
        'mt6833',   // Dimensity 810
        'mt6768',   // Helio G85 / G88
      ];

      if (cpuinfoContent.isNotEmpty) {
        if (twoCorePerfChips.any((c) => cpuinfoContent.contains(c))) {
          debugPrint('🧵 Using 2 threads (known 2-perf-core chip detected)');
          return 2;
        }
      }

      // Strategy 2: Dynamic — count cores with max_freq > 1.8GHz
      // Performance cores run at higher frequencies than efficiency cores.
      // This works for any device, including unknown/future chips.
      final perfCores = await _countPerformanceCores();
      if (perfCores > 0) {
        final threads = perfCores.clamp(2, 4);
        debugPrint(
          '🧵 Using $threads threads ($perfCores perf cores detected dynamically)',
        );
        return threads;
      }

      // Strategy 3: Safe default for ARM
      debugPrint('🧵 Using 4 threads (default for ARM processors)');
      return 4;
    } catch (e) {
      debugPrint('⚠️ Failed to detect CPU cores: $e, defaulting to 4 threads');
      return 4; // Safe fallback
    }
  }

  /// Counts performance cores by reading max CPU frequency from sysfs.
  /// Cores with max_freq > 1.8GHz are considered performance cores.
  /// Returns 0 if sysfs is inaccessible (caller uses safe default).
  static Future<int> _countPerformanceCores() async {
    try {
      final cpuDir = Directory('/sys/devices/system/cpu');
      if (!await cpuDir.exists()) return 0;

      int perfCores = 0;
      final entities = await cpuDir.list().toList();
      for (final entity in entities) {
        // Match cpu0, cpu1, ..., cpuN directories
        if (!RegExp(r'cpu\d+$').hasMatch(entity.path)) continue;
        final freqFile = File('${entity.path}/cpufreq/cpuinfo_max_freq');
        if (await freqFile.exists()) {
          final freqStr = (await freqFile.readAsString()).trim();
          final freq = int.tryParse(freqStr) ?? 0;
          // FIX 5: A true performance core on modern Snapdragon is always >= 2.0 GHz
          const int perfCoreMinFreqKhz = 2000000;
          if (freq >= perfCoreMinFreqKhz) perfCores++;
        }
      }
      debugPrint('🔍 Dynamic core scan: $perfCores performance cores found');
      return perfCores;
    } catch (_) {
      return 0; // sysfs inaccessible — caller uses safe default
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FIX 1: Device tier detection using BOTH RAM AND chip score
  // ═══════════════════════════════════════════════════════════════════════

  /// 📱 Device tier detection based on RAM + chip generation.
  /// Both RAM AND chip score must qualify for High Spec.
  static Future<ModelConfig> _detectDeviceTier(String cpuinfoContent) async {
    try {
      if (Platform.isAndroid) {
        int totalBytes = 0;

        // FIX 6: Rely exclusively on /proc/meminfo to avoid faulty data maps
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

        // Convert to GB using explicit double division
        final double totalRamGb =
            totalBytes.toDouble() / (1024.0 * 1024.0 * 1024.0);

        debugPrint(
          '📱 Device RAM: ${totalRamGb.toStringAsFixed(2)} GB ($totalBytes bytes)',
        );

        // FIX 1: Get chip performance score (0=budget, 1=mid, 2=flagship)
        final chipScore = await _getChipScoreAsync();
        debugPrint('🔍 Chip performance score: $chipScore (0=budget, 1=mid, 2=flagship)');

        // FIX 1: High Spec requires BOTH sufficient RAM AND modern chip
        // Budget 8GB chips (Dimensity 810, SD 730G) are correctly downgraded
        if (totalRamGb >= 6.5 && chipScore >= 2) {
          debugPrint('✅ Performance Mode activated (≥6.5GB + flagship chip)');
          return ModelConfig.highSpec();
        }
        // Mid Spec: adequate RAM OR mid-range chip
        if (totalRamGb >= 5.2 || chipScore >= 1) {
          debugPrint('⚖️ Balanced Mode activated (RAM=${totalRamGb.toStringAsFixed(1)}GB, chipScore=$chipScore)');
          return ModelConfig.midSpec();
        }
        // Low Spec / Efficiency: everything else
        debugPrint('🛡️ Efficiency Mode activated (RAM=${totalRamGb.toStringAsFixed(1)}GB, chipScore=$chipScore)');
        return ModelConfig.lowSpec();
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

            // FIX 8: Need at least 800MB free (ensures at least compute buffers fit in all cases)
            const requiredGb = 0.8;
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

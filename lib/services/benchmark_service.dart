import 'dart:async';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import '../utils/memory_utils.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'model_download_service.dart';
import 'device_config_service.dart';

// ══════════════════════════════════════════════════════════════════════
//  DATA CLASSES
// ══════════════════════════════════════════════════════════════════════

/// Result of a single benchmark inference run.
class BenchmarkRunResult {
  final String promptLabel;
  final int promptTokenEstimate;
  final int ttftMs;
  final double tps;
  final int latencyMs;
  final int tokensGenerated;
  final int peakRamKb;

  const BenchmarkRunResult({
    required this.promptLabel,
    required this.promptTokenEstimate,
    required this.ttftMs,
    required this.tps,
    required this.latencyMs,
    required this.tokensGenerated,
    required this.peakRamKb,
  });
}

/// Averaged metrics for one prompt length.
class PromptAverage {
  final String promptLabel;
  final int avgTtftMs;
  final double avgTps;
  final int avgLatencyMs;
  final int avgTokens;
  final int runCount;

  const PromptAverage({
    required this.promptLabel,
    required this.avgTtftMs,
    required this.avgTps,
    required this.avgLatencyMs,
    required this.avgTokens,
    required this.runCount,
  });
}

/// Full benchmark report with all 8 metrics.
class BenchmarkReport {
  final String deviceName;
  final String androidVersion;
  final String chipset;
  final int totalRamMb;
  final double ggufSizeGb;
  final int modelLoadTimeMs;
  final int batteryBefore;
  final int batteryAfter;
  final int baselineRamKb;
  final int modelLoadedRamKb;
  final int peakInferenceRamKb;
  final List<BenchmarkRunResult> runs;
  final DateTime timestamp;
  final bool usedMlock;

  const BenchmarkReport({
    required this.deviceName,
    required this.androidVersion,
    required this.chipset,
    required this.totalRamMb,
    required this.ggufSizeGb,
    required this.modelLoadTimeMs,
    required this.batteryBefore,
    required this.batteryAfter,
    required this.baselineRamKb,
    required this.modelLoadedRamKb,
    required this.peakInferenceRamKb,
    required this.runs,
    required this.timestamp,
    required this.usedMlock,
  });

  /// Get runs grouped by prompt label, returning averages.
  Map<String, PromptAverage> get averagesByPrompt {
    final grouped = <String, List<BenchmarkRunResult>>{};
    for (final run in runs) {
      grouped.putIfAbsent(run.promptLabel, () => []).add(run);
    }
    return grouped.map(
      (label, runs) => MapEntry(
        label,
        PromptAverage(
          promptLabel: label,
          avgTtftMs:
              (runs.map((r) => r.ttftMs).reduce((a, b) => a + b) / runs.length)
                  .round(),
          avgTps: runs.map((r) => r.tps).reduce((a, b) => a + b) / runs.length,
          avgLatencyMs:
              (runs.map((r) => r.latencyMs).reduce((a, b) => a + b) /
                      runs.length)
                  .round(),
          avgTokens:
              (runs.map((r) => r.tokensGenerated).reduce((a, b) => a + b) /
                      runs.length)
                  .round(),
          runCount: runs.length,
        ),
      ),
    );
  }

  // ─── RAM metrics ───────────────────────────────────────────────────────────
  // Stored values are MemAvailable KB (higher = more free RAM).
  // All values use the baseline as reference: consumed = baseline - current.
  //
  //  baselineRamKb        = MemAvailable BEFORE model load (reference point)
  //  modelLoadedRamKb     = MemAvailable AFTER model load
  //  peakInferenceRamKb   = MINIMUM MemAvailable seen during inference

  // How much RAM the app alone uses (approx, based on total - available)
  int get baselineRamMb =>
      ((totalRamMb * 1024) - baselineRamKb).clamp(0, totalRamMb * 1024) ~/ 1024;

  // Model footprint = drop in MemAvailable after loading
  int get modelFootprintMb =>
      ((baselineRamKb - modelLoadedRamKb) / 1024).round().clamp(0, totalRamMb);

  // RAM in use after model loaded = app + model
  int get modelLoadedRamInMb => (baselineRamMb + modelFootprintMb);

  // Peak RAM consumed = maximum drop in MemAvailable during inference
  int get peakRamMb => ((baselineRamKb - peakInferenceRamKb) / 1024)
      .round()
      .clamp(0, totalRamMb);

  // Extra RAM used during inference beyond model load
  int get inferenceOverheadMb =>
      (peakRamMb - modelFootprintMb).clamp(0, totalRamMb);

  // Battery
  int get batteryDrain => batteryBefore - batteryAfter;

  /// Generate shareable plain-text report.
  String toShareableReport() {
    final buf = StringBuffer();
    buf.writeln('======================================');
    buf.writeln('  SHIKSHA AI - DEVICE BENCHMARK REPORT');
    buf.writeln('======================================');
    buf.writeln();
    buf.writeln('Date    : ${timestamp.toLocal().toString().split('.').first}');
    buf.writeln('Device  : $deviceName');
    buf.writeln('Chipset : $chipset');
    buf.writeln('Android : $androidVersion');
    buf.writeln('RAM     : $totalRamMb MB');
    buf.writeln();

    buf.writeln('--- MODEL INFO ---');
    buf.writeln('GGUF File Size  : ${ggufSizeGb.toStringAsFixed(2)} GB');
    buf.writeln('Model Load Time : ${_fmtMs(modelLoadTimeMs)}');
    buf.writeln();

    buf.writeln('--- INFERENCE PERFORMANCE ---');
    final avgs = averagesByPrompt;
    final labels = avgs.keys.toList();

    // Header
    buf.write('Metric'.padRight(16));
    for (final l in labels) {
      buf.write('| ${l.padLeft(10)} ');
    }
    buf.writeln();
    buf.write(''.padRight(16, '-'));
    for (final _ in labels) {
      buf.write('+${''.padRight(12, '-')}');
    }
    buf.writeln();

    // TTFT
    buf.write('TTFT (ms)'.padRight(16));
    for (final l in labels) {
      buf.write('| ${avgs[l]!.avgTtftMs.toString().padLeft(10)} ');
    }
    buf.writeln();

    // TPS
    buf.write('TPS (tok/s)'.padRight(16));
    for (final l in labels) {
      buf.write('| ${avgs[l]!.avgTps.toStringAsFixed(1).padLeft(10)} ');
    }
    buf.writeln();

    // Latency
    buf.write('Latency (ms)'.padRight(16));
    for (final l in labels) {
      buf.write('| ${avgs[l]!.avgLatencyMs.toString().padLeft(10)} ');
    }
    buf.writeln();

    // Tokens
    buf.write('Avg Tokens'.padRight(16));
    for (final l in labels) {
      buf.write('| ${avgs[l]!.avgTokens.toString().padLeft(10)} ');
    }
    buf.writeln();

    buf.writeln('--- RAM USAGE (System-Wide via MemAvailable) ---');
    final memMode = usedMlock ? 'mlock' : 'mmap';
    buf.writeln('Baseline System RAM In-Use : $baselineRamMb MB');
    buf.writeln('System RAM After Load      : $modelLoadedRamInMb MB');
    buf.writeln('Model Footprint ($memMode)  : $modelFootprintMb MB');
    buf.writeln('Peak Inference RAM Delta   : $peakRamMb MB');
    buf.writeln('Inference Overhead (KV+Compute): $inferenceOverheadMb MB');  // FIX 8: Updated label
    buf.writeln();

    buf.writeln('--- BATTERY ---');
    buf.writeln('Before : $batteryBefore%');
    buf.writeln('After  : $batteryAfter%');
    buf.writeln('Drain  : $batteryDrain%');

    return buf.toString();
  }

  static String _fmtMs(int ms) {
    if (ms >= 1000) {
      return '${(ms / 1000).toStringAsFixed(1)}s (${ms}ms)';
    }
    return '${ms}ms';
  }
}

// ══════════════════════════════════════════════════════════════════════
//  PROGRESS CALLBACK
// ══════════════════════════════════════════════════════════════════════

typedef BenchmarkProgressCallback =
    void Function(int currentStep, int totalSteps, String label);

// ══════════════════════════════════════════════════════════════════════
//  BENCHMARK PROMPTS
// ══════════════════════════════════════════════════════════════════════

class BenchmarkPrompt {
  final String label;
  final int estimatedTokens;
  final String text;

  const BenchmarkPrompt({
    required this.label,
    required this.estimatedTokens,
    required this.text,
  });
}

const List<BenchmarkPrompt> benchmarkPrompts = [
  BenchmarkPrompt(
    label: '~10 tok',
    estimatedTokens: 10,
    text: 'What is gravity?',
  ),
  BenchmarkPrompt(
    label: '~30 tok',
    estimatedTokens: 30,
    text:
        'How does heating change a solid into a liquid? What happens to the particles during melting?',
  ),
  BenchmarkPrompt(
    label: '~50 tok',
    estimatedTokens: 50,
    text:
        "I don't understand how photosynthesis works in plants. If plants don't eat food like us, how do they make their own food using sunlight? What roles do carbon dioxide and water play in this process? Please explain it in a simple way.",
  ),
  BenchmarkPrompt(
    label: '~100 tok',
    estimatedTokens: 100,
    text:
        "I am confused about solving linear equations with variables on both sides. For example, in the equation 3x + 5 = 2x + 12, I don't understand why we subtract 2x from both sides instead of moving numbers first. Also, sometimes I make mistakes with negative signs when rearranging terms. Can you please explain step-by-step how to solve this type of equation and how to avoid common errors while simplifying expressions?",
  ),
];

// ══════════════════════════════════════════════════════════════════════
//  BENCHMARK SERVICE
// ══════════════════════════════════════════════════════════════════════

class BenchmarkService {
  final ModelDownloadService _downloadService;

  LlamaParent? _llamaParent;
  StreamSubscription? _streamSubscription;
  StreamController<String>? _tokenController;
  bool _isCancelled = false;

  // Cached config — read once, reused for all context reloads
  String? _cachedModelPath;
  ModelConfig? _cachedConfig;

  // FIX 4: Track whether mlock was used for the current benchmark load
  bool _useMlock = false;

  static const int runsPerPrompt = 3;
  static const int totalRuns = 12; // 4 prompts x 3 runs
  static const int totalSteps = 13; // 1 warm-up + 12 runs

  /// Max tokens per benchmark run. Capped at 128 to keep runs short
  /// (~10-15s each instead of 25-98s), reduce heating, and still
  /// provide stable TPS measurement.
  static const int _benchmarkMaxTokens = 128;

  /// FIX 7: Cooldown delay between runs (seconds). ARM chips need
  /// 8-12s minimum to dissipate heat after sustained CPU load.
  /// With 2s cooldown, runs 4-5 show artificially low TPS. (was 2)
  static const int _cooldownSeconds = 10;



  BenchmarkService(this._downloadService);

  void _log(String msg) {
    if (kDebugMode) debugPrint('[BENCHMARK] $msg');
  }

  /// Cancel the benchmark.
  void cancel() {
    _isCancelled = true;
    _tokenController?.close();
    _log('Benchmark cancelled');
  }



  // ────────────────────────────────────────────────────────────────────
  //  RAM SNAPSHOT  (MemAvailable from /proc/meminfo)
  // ────────────────────────────────────────────────────────────────────

  /// Reads MemAvailable from /proc/meminfo in KB.
  /// This is the kernel's own accounting — always accurate and never
  /// exceeds physical RAM (unlike VmRSS which can be inflated on
  /// Qualcomm devices due to multi-process virtual memory accounting).
  Future<int> readMemAvailableKb() async {
    try {
      final memFile = File('/proc/meminfo');
      if (await memFile.exists()) {
        final lines = await memFile.readAsLines();
        for (final line in lines) {
          if (line.startsWith('MemAvailable:')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              return int.tryParse(parts[1]) ?? 0;
            }
          }
        }
      }
    } catch (e) {
      _log('Failed to read MemAvailable: $e');
    }
    return 0;
  }

  // ────────────────────────────────────────────────────────────────────
  //  CHIPSET NAME RESOLVER
  // ────────────────────────────────────────────────────────────────────

  /// Maps /proc/cpuinfo Hardware codenames to marketing names.
  /// Dynamic: reads the actual device codename at runtime, maps to marketing name.
  /// Falls back to title-cased raw codename for any unknown chips.
  String _resolveChipsetName(String raw, String hardware, String board) {
    // ── Qualcomm Snapdragon — codename → marketing name ──────────────
    const qualcomm = <String, String>{
      // Snapdragon 8 Elite / Gen 4
      'sun': 'Snapdragon 8 Elite',
      // Snapdragon 8 Gen 3 / 7+ Gen 3 (same silicon family)
      'pineapple': 'Snapdragon 8 Gen 3 / 7+ Gen 3',
      // Snapdragon 8 Gen 2
      'kalama': 'Snapdragon 8 Gen 2',
      // Snapdragon 8 Gen 1 / 8+ Gen 1
      'taro': 'Snapdragon 8 Gen 1 / 8+ Gen 1',
      // Snapdragon 888 / 888+
      'lahaina': 'Snapdragon 888 / 888+',
      // Snapdragon 870 / 865 / 865+
      'kona': 'Snapdragon 865 / 870',
      // Snapdragon 855 / 855+
      'msmnile': 'Snapdragon 855 / 855+',
      // Snapdragon 845
      'sdm845': 'Snapdragon 845',
      // Snapdragon 835
      'msm8998': 'Snapdragon 835',
      // Snapdragon 7 Gen 3
      'crow': 'Snapdragon 7 Gen 3',
      // Snapdragon 7+ Gen 2
      'cape': 'Snapdragon 7+ Gen 2',
      // Snapdragon 7 Gen 1
      'sm7450': 'Snapdragon 7 Gen 1',
      // Snapdragon 782G / 778G / 778G+
      'yupik': 'Snapdragon 778G / 782G',
      // Snapdragon 780G
      'sm7350': 'Snapdragon 780G',
      // Snapdragon 768G / 765G / 765
      'lito': 'Snapdragon 765G / 768G',
      // Snapdragon 750G
      'atoll': 'Snapdragon 750G',
      // Snapdragon 732G / 730G / 730
      'trinket': 'Snapdragon 730G / 732G',
      // Snapdragon 730G (alternate cpuinfo identifier)
      'sm7150': 'Snapdragon 730G / 732G',
      // Snapdragon 720G
      'sm6350': 'Snapdragon 720G',
      // Snapdragon 710 / 712
      'sdm710': 'Snapdragon 710 / 712',
      // Snapdragon 695
      'sm6375': 'Snapdragon 695',
      // Snapdragon 690
      'sm6350_lite': 'Snapdragon 690',
      // Snapdragon 680 / 678
      'khaje': 'Snapdragon 680 / 678',
      // Snapdragon 662 / 665 / 680
      'bengal': 'Snapdragon 662 / 665',
      // Snapdragon 480 / 480+
      'sm4350': 'Snapdragon 480 / 480+',
      // Snapdragon 460
      'trinket_go': 'Snapdragon 460',
      // Snapdragon 439 / 450
      'sdm439': 'Snapdragon 439 / 450',
      // Snapdragon 430 / 435
      'msm8937': 'Snapdragon 430 / 435',
    };

    // ── MediaTek — chip model number → marketing name ─────────────────
    // MediaTek chips appear in /proc/cpuinfo as their model number (mt6xxx)
    const mediatek = <String, String>{
      // Dimensity 9000 series (flagship)
      'mt6983': 'MediaTek Dimensity 9200',
      'mt6985': 'MediaTek Dimensity 9300',
      'mt6989': 'MediaTek Dimensity 9400',
      'mt6982': 'MediaTek Dimensity 9000',
      'mt6971': 'MediaTek Dimensity 9000+',
      'mt6979': 'MediaTek Dimensity 9300+',
      // Dimensity 8000 series (upper-mid)
      'mt6895': 'MediaTek Dimensity 8300',
      'mt6886': 'MediaTek Dimensity 8200',
      'mt6879': 'MediaTek Dimensity 8050 / 8100',
      'mt6896': 'MediaTek Dimensity 8000',
      // Dimensity 7000 series (mid-range)
      'mt6878': 'MediaTek Dimensity 7300',
      'mt6835': 'MediaTek Dimensity 7200',
      'mt6877': 'MediaTek Dimensity 900 / 920',
      'mt6833': 'MediaTek Dimensity 810',
      'mt6853': 'MediaTek Dimensity 800U',
      'mt6855': 'MediaTek Dimensity 7020',
      // Dimensity 1000 series
      'mt6893': 'MediaTek Dimensity 1200',
      'mt6891': 'MediaTek Dimensity 1100',
      'mt6889': 'MediaTek Dimensity 1000+',
      // Helio G series (gaming mid-range)
      'mt6781': 'MediaTek Helio G96 / G99',
      'mt6785': 'MediaTek Helio G90T',
      'mt6769': 'MediaTek Helio G85 / G88',
      'mt6765': 'MediaTek Helio G35 / G85',
      'mt6762': 'MediaTek Helio G25 / G35',
      // Helio P series (budget)
      'mt6771': 'MediaTek Helio P70 / P60',
      'mt6768': 'MediaTek Helio P65',
      'mt6757': 'MediaTek Helio P20 / P25',
    };

    // ── Samsung Exynos ────────────────────────────────────────────────
    const exynos = <String, String>{
      'exynos2400': 'Samsung Exynos 2400',
      'exynos2200': 'Samsung Exynos 2200',
      'exynos2100': 'Samsung Exynos 2100',
      'exynos990': 'Samsung Exynos 990',
      'exynos980': 'Samsung Exynos 980',
      'exynos9820': 'Samsung Exynos 9820',
      'exynos9810': 'Samsung Exynos 9810',
      'exynos850': 'Samsung Exynos 850',
      'exynos7885': 'Samsung Exynos 7885',
      's5e8845': 'Samsung Exynos 1480',
      's5e8535': 'Samsung Exynos 1380',
      's5e8835': 'Samsung Exynos 2400',
    };

    // ── Google Tensor ─────────────────────────────────────────────────
    const tensor = <String, String>{
      'zuma': 'Google Tensor G3',
      'cloudripper': 'Google Tensor G2',
      'oriole': 'Google Tensor G1',
    };

    // ── Unisoc (common in budget Indian/African market phones) ────────
    const unisoc = <String, String>{
      'ums9620': 'Unisoc T820',
      'sc9863a': 'Unisoc SC9863A',
      'sc7731e': 'Unisoc SC7731E',
      'ums512': 'Unisoc T618',
      'ums9230': 'Unisoc T606 / T612',
    };

    // ── HiSilicon Kirin (older Huawei/Honor) ─────────────────────────
    const kirin = <String, String>{
      'kirin9000': 'HiSilicon Kirin 9000',
      'kirin990': 'HiSilicon Kirin 990',
      'kirin980': 'HiSilicon Kirin 980',
      'kirin970': 'HiSilicon Kirin 970',
      'kirin960': 'HiSilicon Kirin 960',
    };

    // ── Match function — checks raw /proc/cpuinfo + hardware + board ──
    String? match(Map<String, String> map, {String? prefix}) {
      for (final entry in map.entries) {
        if (raw.contains(entry.key) ||
            hardware.toLowerCase().contains(entry.key) ||
            board.toLowerCase().contains(entry.key)) {
          return prefix != null ? '$prefix ${entry.value}' : entry.value;
        }
      }
      return null;
    }

    return match(qualcomm, prefix: 'Qualcomm') ??
        match(mediatek) ??
        match(exynos) ??
        match(tensor) ??
        match(unisoc) ??
        match(kirin) ??
        // Last resort: title-case the raw codename — always readable
        (raw.isNotEmpty
            ? raw
                  .split(' ')
                  .map(
                    (w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1),
                  )
                  .join(' ')
            : '$hardware ($board)');
  }

  // ────────────────────────────────────────────────────────────────────
  //  DEVICE INFO
  // ────────────────────────────────────────────────────────────────────

  /// Public wrapper — called by the screen on open to pre-load
  /// device name and chipset for the header card.
  Future<Map<String, dynamic>> collectDeviceInfoPublic() =>
      _collectDeviceInfo();

  Future<Map<String, dynamic>> _collectDeviceInfo() async {
    final deviceInfo = DeviceInfoPlugin();
    String deviceName = 'Unknown';
    String androidVersion = 'Unknown';
    String chipset = 'Unknown';
    int totalRamMb = 0;

    try {
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        deviceName = '${info.brand} ${info.model}';
        androidVersion =
            'Android ${info.version.release} (SDK ${info.version.sdkInt})';

        // Default to resolving from hardware/board fields in case /proc/cpuinfo
        // is inaccessible or doesn't have the Hardware line (common in Android 10+)
        chipset = _resolveChipsetName('', info.hardware, info.board);

        // Get chipset/SoC info — read /proc/cpuinfo Hardware line (codename)
        // then map it to the marketing name users know.
        try {
          final cpuFile = File('/proc/cpuinfo');
          if (await cpuFile.exists()) {
            final lines = await cpuFile.readAsLines();
            for (final line in lines) {
              if (line.startsWith('Hardware')) {
                final raw = line.split(':').last.trim().toLowerCase();
                // Override fallback with actual /proc/cpuinfo codename map
                chipset = _resolveChipsetName(raw, info.hardware, info.board);
                break;
              }
            }
          }
        } catch (_) {}

        // Read total RAM
        try {
          final memFile = File('/proc/meminfo');
          if (await memFile.exists()) {
            final lines = await memFile.readAsLines();
            for (final line in lines) {
              if (line.startsWith('MemTotal:')) {
                final parts = line.split(RegExp(r'\s+'));
                if (parts.length >= 2) {
                  final kb = int.tryParse(parts[1]) ?? 0;
                  totalRamMb = (kb / 1024).round();
                }
                break;
              }
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      _log('Device info failed: $e');
    }

    return {
      'deviceName': deviceName,
      'androidVersion': androidVersion,
      'chipset': chipset,
      'totalRamMb': totalRamMb,
    };
  }

  // ────────────────────────────────────────────────────────────────────
  //  BUILD LOAD COMMAND (uses cached config)
  // ────────────────────────────────────────────────────────────────────

  /// Creates a LlamaLoad command using cached config.
  /// nPredict is capped at _benchmarkMaxTokens for shorter runs.
  /// FIX 4: Uses dynamic mlock/mmap based on _useMlock.
  LlamaLoad _buildLoadCommand() {
    final config = _cachedConfig!;
    return LlamaLoad(
      path: _cachedModelPath!,
      modelParams: ModelParams()
        ..nGpuLayers = config.nGpuLayers
        ..useMemorymap = !_useMlock  // FIX 4: mmap off when mlocking
        ..useMemoryLock = _useMlock, // FIX 4: lock full model into RAM
      contextParams: ContextParams()
        ..nCtx = config.contextSize
        ..nThreads = config.threads
        ..nBatch = config.batchSize
        ..nPredict = _benchmarkMaxTokens, // Capped for benchmark
      samplingParams: SamplerParams()
        ..temp = 0.7
        ..topP = 0.8
        ..topK = 40
        ..penaltyRepeat = 1.05,
      format: ChatMLFormat(),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  //  SINGLE INFERENCE
  // ────────────────────────────────────────────────────────────────────

  /// Runs a single inference, collects TTFT/TPS/Latency/RAM.
  /// Returns null if cancelled.
  Future<BenchmarkRunResult?> _runSingleInference(
    BenchmarkPrompt prompt, {
    int maxTokensToGenerate = 0, // Used for 1-token warmup
  }) async {
    if (_isCancelled || _llamaParent == null) return null;

    // Build bare ChatML prompt
    final formattedPrompt =
        '<'
        '|im_start|'
        '>user\n${prompt.text}<'
        '|im_end|'
        '>\n<'
        '|im_start|'
        '>assistant\n';

    // Prepare stream controller for this run
    _tokenController?.close();
    _tokenController = StreamController<String>();

    // Set up token listener
    await _streamSubscription?.cancel();
    _streamSubscription = _llamaParent!.stream.listen(
      (token) {
        if (_tokenController != null && !_tokenController!.isClosed) {
          _tokenController!.add(token);
        }
      },
      onError: (error) {
        _log('Stream error: $error');
        if (_tokenController != null && !_tokenController!.isClosed) {
          _tokenController!.close();
        }
      },
      onDone: () {
        if (_tokenController != null && !_tokenController!.isClosed) {
          _tokenController!.close();
        }
      },
    );

    // Timing
    final wallClock = Stopwatch()..start();
    Stopwatch? decodeTimer;
    bool firstTokenReceived = false;
    int ttftMs = 0;
    int tokenCount = 0;
    // Track minimum MemAvailable during inference (lower = more RAM used)
    int minMemAvailableKb = 0;

    // EOS markers (split to avoid text processing issues)
    final eosImEnd =
        '<'
        '|im_end|'
        '>';
    final eosEndOfText =
        '<'
        '|endoftext|'
        '>';
    final eosSlash =
        '<'
        '/s'
        '>';

    // Send prompt
    _log('Sending prompt: "${prompt.label}"');
    _llamaParent!.sendPrompt(formattedPrompt);

    // Timeout for first token
    Timer? firstTokenTimeout;
    firstTokenTimeout = Timer(const Duration(seconds: 45), () {
      _log('First token timeout!');
      _tokenController?.close();
    });

    // Timeout for between tokens
    Timer? interTokenTimeout;

    try {
      await for (final token in _tokenController!.stream) {
        if (_isCancelled) break;

        // Check for EOS
        if (token.contains(eosImEnd) ||
            token.contains(eosEndOfText) ||
            token.contains(eosSlash)) {
          final cleanToken = token
              .replaceAll(eosImEnd, '')
              .replaceAll(eosEndOfText, '')
              .replaceAll(eosSlash, '');
          if (cleanToken.trim().isNotEmpty) {
            tokenCount++;
          }
          break;
        }

        // Skip empty tokens
        if (token.isEmpty) continue;

        // First token handling
        if (!firstTokenReceived) {
          firstTokenReceived = true;
          ttftMs = wallClock.elapsedMilliseconds;
          decodeTimer = Stopwatch()..start();
          firstTokenTimeout.cancel();
          _log('First token at ${ttftMs}ms');
        }

        tokenCount++;
        
        // FIX 3: Stop early if maxTokensToGenerate is specified (used for warmup)
        if (maxTokensToGenerate > 0 && tokenCount >= maxTokensToGenerate) {
          break;
        }

        // RAM sampling every 20 tokens — track minimum MemAvailable
        if (tokenCount % 20 == 0) {
          final available = await readMemAvailableKb();
          if (minMemAvailableKb == 0 || available < minMemAvailableKb) {
            minMemAvailableKb = available;
          }
        }

        // Reset inter-token timeout (5s max between tokens)
        interTokenTimeout?.cancel();
        interTokenTimeout = Timer(const Duration(seconds: 5), () {
          _tokenController?.close();
        });
      }
    } catch (e) {
      _log('Inference error: $e');
    } finally {
      firstTokenTimeout.cancel();
      interTokenTimeout?.cancel();
    }

    wallClock.stop();
    decodeTimer?.stop();

    // One final MemAvailable sample
    final finalAvailable = await readMemAvailableKb();
    if (minMemAvailableKb == 0 || finalAvailable < minMemAvailableKb) {
      minMemAvailableKb = finalAvailable;
    }

    // Calculate TPS
    final decodeMs = decodeTimer?.elapsedMilliseconds ?? 1;
    final tps = tokenCount > 0 ? (tokenCount / (decodeMs / 1000.0)) : 0.0;

    final result = BenchmarkRunResult(
      promptLabel: prompt.label,
      promptTokenEstimate: prompt.estimatedTokens,
      ttftMs: ttftMs,
      tps: tps,
      latencyMs: wallClock.elapsedMilliseconds,
      tokensGenerated: tokenCount,
      peakRamKb:
          minMemAvailableKb, // stored as raw MemAvailable; converted in report
    );

    _log(
      'Run complete: ${prompt.label} | TTFT=${ttftMs}ms TPS=${tps.toStringAsFixed(1)} '
      'Latency=${wallClock.elapsedMilliseconds}ms Tokens=$tokenCount',
    );

    return result;
  }

  // ────────────────────────────────────────────────────────────────────
  //  FIX 6: Lightweight context reset — keeps model in RAM
  //  Only re-creates stream subscription without dispose/reload.
  //  This resets the stream state without evicting warm model pages.
  //  ⚠️ WARNING: Strictly for benchmarking only. It bypasses proper KV cache 
  //  invalidation and will cause context-bleed if used in real chat sessions.
  // ────────────────────────────────────────────────────────────────────

  Future<void> _lightweightContextReset() async {
    if (_isCancelled || _llamaParent == null) return;

    // Cancel old stream subscription
    await _streamSubscription?.cancel();
    _streamSubscription = null;

    // Small delay to let stream cleanup complete
    await Future.delayed(const Duration(milliseconds: 200));

    _log('Lightweight context reset (subscription cancelled, model stays warm \u2014 re-subscribed on next run)');
  }

  // Keep the full reload method for safety — used only when context overflows
  Future<void> _fullReloadContext() async {
    if (_isCancelled || _llamaParent == null) return;

    await _streamSubscription?.cancel();
    _streamSubscription = null;

    _llamaParent?.dispose();
    _llamaParent = null;

    // FIX 2: Wait 800ms to allow OS to reclaim native memory before mlock check
    await Future.delayed(const Duration(milliseconds: 800));

    // FIX 6: Re-evaluate mlock safety before rebuilding the model
    // RAM may have dropped significantly mid-benchmark.
    _useMlock = await MemoryUtils.shouldUseMlock(_cachedConfig!);

    _llamaParent = LlamaParent(_buildLoadCommand());
    await _llamaParent!.init();

    _log('Full context reloaded (model reloaded from disk; useMlock=$_useMlock)');
  }

  // ────────────────────────────────────────────────────────────────────
  //  MAIN BENCHMARK FLOW
  // ────────────────────────────────────────────────────────────────────

  /// Runs the full benchmark suite.
  /// [unloadChatModel] — callback to unload the chat model before starting.
  /// [onProgress] — progress callback for UI.
  Future<BenchmarkReport> runBenchmark({
    required Future<void> Function() unloadChatModel,
    BenchmarkProgressCallback? onProgress,
  }) async {
    _isCancelled = false;
    final results = <BenchmarkRunResult>[];

    _log('═══ BENCHMARK STARTING ═══');

    // ── Step 1: Collect device info ──
    onProgress?.call(0, totalSteps, 'Collecting device info...');
    final deviceInfo = await _collectDeviceInfo();

    // ── Step 2: Read battery before ──
    final battery = Battery();
    int batteryBefore = 0;
    try {
      batteryBefore = await battery.batteryLevel;
      _log('Battery before: $batteryBefore%');
    } catch (e) {
      _log('Battery read failed: $e');
    }

    // ── Step 3: Snapshot 1 — Baseline RAM ──
    // Read MemAvailable from the OS — the most RAM free right now
    final baselineMemAvailableKb = await readMemAvailableKb();
    _log(
      'Baseline MemAvailable: ${(baselineMemAvailableKb / 1024).round()} MB',
    );

    // We store baseline as KB used = approx 0 (reference point).
    // baselineRamKb in BenchmarkReport is the baseline MemAvailable itself,
    // used as the reference for computing footprint later.
    final baselineRamKb = baselineMemAvailableKb;

    // ── Step 4: Get GGUF file size + cache model path ──
    _cachedModelPath = await _downloadService.getModelPath();
    double ggufSizeGb = 0.0;
    try {
      final modelFile = File(_cachedModelPath!);
      if (await modelFile.exists()) {
        final bytes = await modelFile.length();
        ggufSizeGb = bytes / (1024.0 * 1024.0 * 1024.0);
      }
    } catch (e) {
      _log('File size read failed: $e');
    }

    // ── Step 5: Unload chat model to free RAM ──
    _log('Unloading chat model...');
    await unloadChatModel();
    await Future.delayed(const Duration(milliseconds: 500));

    // ── Step 6: Cache device config (read once, reuse everywhere) ──
    _cachedConfig = await DeviceProfiler.getBestConfig();
    _log(
      'Config cached: threads=${_cachedConfig!.threads}, '
      'ctx=${_cachedConfig!.contextSize}, '
      'maxTokens=$_benchmarkMaxTokens (capped)',
    );

    // ── Step 7: Load model (timed) ──
    // FIX 4: Check available RAM BEFORE model load to decide mlock
    _useMlock = await MemoryUtils.shouldUseMlock(_cachedConfig!);
    _log('Loading benchmark model (useMlock=$_useMlock)...');
    onProgress?.call(0, totalSteps, 'Loading model...');

    final loadStopwatch = Stopwatch()..start();
    _llamaParent = LlamaParent(_buildLoadCommand());
    await _llamaParent!.init();
    loadStopwatch.stop();
    final modelLoadTimeMs = loadStopwatch.elapsedMilliseconds;
    _log('Model loaded in ${modelLoadTimeMs}ms');

    if (_isCancelled) {
      await _dispose();
      throw Exception('Benchmark cancelled');
    }

    // ── Step 8: Snapshot 2 — Post-load RAM ──
    // Lower MemAvailable = more RAM consumed by model
    final postLoadMemAvailableKb = await readMemAvailableKb();
    // RAM consumed by model = how much MemAvailable dropped
    final modelConsumedKb = baselineRamKb - postLoadMemAvailableKb;
    // Store as "post load available" for peak delta calculation later
    final modelLoadedRamKb = postLoadMemAvailableKb;
    _log(
      'Post-load MemAvailable: ${(postLoadMemAvailableKb / 1024).round()} MB '
      '(model consumed: ${(modelConsumedKb / 1024).round()} MB)',
    );

    // ── Step 9: Warm-up run ──
    _log('Running warm-up inference...');
    onProgress?.call(0, totalSteps, 'Warming up... (0/$totalRuns)');
    
    // FIX 3: Run only 1 token for warmup to populate OS page cache, no generation cost!
    await _runSingleInference(benchmarkPrompts[0], maxTokensToGenerate: 1); // Discard result
    
    // FIX 5: No _reloadContext() here — warm pages must stay in RAM.
    // KV cache from warm-up won't interfere because each sendPrompt()
    // processes fresh ChatML tokens.
    _log('Warm-up complete (model pages now in OS cache)');

    if (_isCancelled) {
      await _dispose();
      throw Exception('Benchmark cancelled');
    }

    // ── Step 10: Timed benchmark runs ──
    int globalPeakRamKb = modelLoadedRamKb;
    int runNumber = 0;
    // FIX 6: Track estimated context position to detect accumulation overflow
    int estimatedContextTokens = _benchmarkMaxTokens; // warm-up tokens
    final contextLimit = _cachedConfig!.contextSize;

    for (final prompt in benchmarkPrompts) {
      for (int i = 0; i < runsPerPrompt; i++) {
        if (_isCancelled) break;

        runNumber++;
        onProgress?.call(
          runNumber,
          totalSteps,
          'Run $runNumber/$totalRuns \u2014 ${prompt.label} prompt',
        );

        final result = await _runSingleInference(prompt);
        if (result != null) {
          results.add(result);
          // Track minimum MemAvailable across all runs (lower = more RAM used)
          if (globalPeakRamKb == 0 || result.peakRamKb < globalPeakRamKb) {
            globalPeakRamKb = result.peakRamKb;
          }
        }

        // FIX 6: Track context fill — each run adds ~benchmarkMaxTokens
        estimatedContextTokens += _benchmarkMaxTokens + (prompt.estimatedTokens);
        _log('Context estimate: ~$estimatedContextTokens / $contextLimit tokens');

        if (runNumber < totalRuns && !_isCancelled) {
          // FIX 6: If context is approaching 75% capacity, do a full reload
          // to prevent overflow (critical on Low Spec ctx=1024).
          // Otherwise, use lightweight reset to keep model pages warm.
          if (estimatedContextTokens > (contextLimit * 0.75).round()) {
            _log('Context nearing capacity — full reload to prevent overflow');
            await _fullReloadContext();
            estimatedContextTokens = 0; // Reset counter after full reload
          } else {
            // FIX 6: Lightweight reset — no model dispose, just stream re-sub
            await _lightweightContextReset();
          }
          // FIX 7: Cooldown between runs — gives CPU thermal headroom
          _log('Cooldown ${_cooldownSeconds}s...');
          await Future.delayed(Duration(seconds: _cooldownSeconds));
        }
      }

      // Thermal recovery cool-down between the 4 prompt size groups
      if (runNumber < totalRuns && !_isCancelled) {
        _log('Batch complete. Inter-batch thermal recovery...');
        onProgress?.call(runNumber, totalSteps, 'Cooling down...');
        await Future.delayed(const Duration(seconds: 5)); // thermal recovery
      }
    }

    if (_isCancelled) {
      await _dispose();
      throw Exception('Benchmark cancelled');
    }

    // ── Step 11: Finalizing ──
    _log('Finalizing benchmark...');
    onProgress?.call(totalSteps - 1, totalSteps, 'Finalizing results...');

    // Allow a frame to render the "Finalizing" state
    await Future.delayed(const Duration(milliseconds: 100));

    // Read battery after
    int batteryAfter = 0;
    try {
      batteryAfter = await battery.batteryLevel;
      _log('Battery after: $batteryAfter%');
    } catch (e) {
      _log('Battery read failed: $e');
    }

    // Cleanup
    await _dispose();

    // Small delay to let native resources fully release
    await Future.delayed(const Duration(milliseconds: 300));

    _log('═══ BENCHMARK COMPLETE ═══');
    _log('Runs completed: ${results.length}/$totalRuns');

    // ── Build report ──
    final report = BenchmarkReport(
      deviceName: deviceInfo['deviceName'] as String,
      androidVersion: deviceInfo['androidVersion'] as String,
      chipset: deviceInfo['chipset'] as String,
      totalRamMb: deviceInfo['totalRamMb'] as int,
      ggufSizeGb: ggufSizeGb,
      modelLoadTimeMs: modelLoadTimeMs,
      batteryBefore: batteryBefore,
      batteryAfter: batteryAfter,
      baselineRamKb: baselineRamKb,
      modelLoadedRamKb: modelLoadedRamKb,
      peakInferenceRamKb: globalPeakRamKb,
      runs: results,
      timestamp: DateTime.now(),
      usedMlock: _useMlock,
    );

    _log('Report built successfully');
    return report;
  }

  // ────────────────────────────────────────────────────────────────────
  //  CLEANUP
  // ────────────────────────────────────────────────────────────────────

  Future<void> _dispose() async {
    _tokenController?.close();
    _tokenController = null;

    await _streamSubscription?.cancel();
    _streamSubscription = null;

    _llamaParent?.dispose();
    _llamaParent = null;

    // Clear cached config
    _cachedModelPath = null;
    _cachedConfig = null;

    _log('Benchmark resources disposed');
  }
}

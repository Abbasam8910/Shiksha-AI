import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../providers/chat_provider.dart';
import '../providers/download_provider.dart';
import '../services/benchmark_service.dart';

class BenchmarkScreen extends ConsumerStatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  ConsumerState<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends ConsumerState<BenchmarkScreen> {
  BenchmarkService? _benchmarkService;
  BenchmarkReport? _report;
  bool _isRunning = false;
  int _currentStep = 0;
  int _totalSteps = BenchmarkService.totalSteps;
  String _progressLabel = '';
  String? _errorMessage;

  // Device info pre-loaded on screen open so header shows chipset
  // even before benchmark starts
  String _preloadedDevice = '';
  String _preloadedChipset = '';

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final service = BenchmarkService(
        // dummy service just for device info — no download needed
        // ignore: invalid_use_of_visible_for_testing_member
        ref.read(modelDownloadServiceProvider),
      );
      final info = await service.collectDeviceInfoPublic();
      if (mounted) {
        setState(() {
          _preloadedDevice = info['deviceName'] as String? ?? '';
          _preloadedChipset = info['chipset'] as String? ?? '';
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _benchmarkService?.cancel();
    WakelockPlus.disable(); // ensure wakelock released on exit
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────
  //  RUN BENCHMARK
  // ────────────────────────────────────────────────────────────────────

  Future<void> _startBenchmark() async {
    final confirmed = await _showConfirmDialog();
    if (!confirmed) return;

    setState(() {
      _isRunning = true;
      _report = null;
      _errorMessage = null;
      _currentStep = 0;
      _progressLabel = 'Preparing...';
    });

    // Keep screen on — prevents CPU throttling which skews TPS
    await WakelockPlus.enable();

    final downloadService = ref.read(modelDownloadServiceProvider);
    _benchmarkService = BenchmarkService(downloadService);

    try {
      final report = await _benchmarkService!.runBenchmark(
        unloadChatModel: () async {
          final llmService = ref.read(llmServiceProvider);
          await llmService.unloadModel();
        },
        onProgress: (step, total, label) {
          if (mounted) {
            setState(() {
              _currentStep = step;
              _totalSteps = total;
              _progressLabel = label;
            });
          }
        },
      );

      debugPrint('[BENCHMARK_UI] Report received, showing results...');

      if (mounted) {
        setState(() {
          _report = report;
          _isRunning = false;
          _progressLabel = 'Complete!';
        });
      }
    } catch (e, stackTrace) {
      debugPrint('[BENCHMARK_UI] Error: $e');
      debugPrint('[BENCHMARK_UI] Stack: $stackTrace');
      if (mounted) {
        setState(() {
          _isRunning = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    } finally {
      // Always release wakelock when done, cancelled, or errored
      await WakelockPlus.disable();
    }
  }

  void _cancelBenchmark() {
    _benchmarkService?.cancel();
    setState(() {
      _isRunning = false;
      _progressLabel = 'Cancelled';
    });
  }

  Future<bool> _showConfirmDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(Icons.science, color: Color(0xFF8B7FD6)),
                const SizedBox(width: 8),
                Text(
                  'Run Benchmark?',
                  style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: Text(
              'This will:\n\n'
              '• Temporarily unload the AI model\n'
              '• Run 12 test inferences (~3-4 min)\n'
              '• The model will auto-reload when you return to chat\n\n'
              'Keep the screen on during the benchmark.',
              style: GoogleFonts.inter(
                fontSize: 14,
                color: Colors.grey[700],
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(color: Colors.grey[500]),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF8B7FD6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  'Start Benchmark',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ────────────────────────────────────────────────────────────────────
  //  SHARE REPORT
  // ────────────────────────────────────────────────────────────────────

  void _shareReport() {
    if (_report == null) return;
    final text = _report!.toShareableReport();
    Share.share(text);
  }

  // ────────────────────────────────────────────────────────────────────
  //  RATING HELPERS
  // ────────────────────────────────────────────────────────────────────

  String _ttftRating(int ms) {
    if (ms < 1000) return '⚡ Excellent';
    if (ms <= 2000) return '✅ Good';
    if (ms <= 4000) return '⚠️ Acceptable';
    return '🐢 Slow';
  }

  Color _ttftColor(int ms) {
    if (ms < 1000) return const Color(0xFF10B981);
    if (ms <= 2000) return const Color(0xFF3B82F6);
    if (ms <= 4000) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  String _tpsRating(double tps) {
    if (tps > 20) return '⚡ Real-time';
    if (tps >= 10) return '✅ Smooth';
    if (tps >= 5) return '⚠️ Usable';
    return '🐢 Slow';
  }

  Color _tpsColor(double tps) {
    if (tps > 20) return const Color(0xFF10B981);
    if (tps >= 10) return const Color(0xFF3B82F6);
    if (tps >= 5) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  // ────────────────────────────────────────────────────────────────────
  //  BUILD
  // ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Device Benchmark',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: const Color(0xFF1A1A1A),
            fontSize: 22,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF1A1A1A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(),
            const SizedBox(height: 20),

            // Run/Progress/Cancel
            if (!_isRunning && _report == null) _buildRunButton(),
            if (_isRunning) _buildProgressCard(),
            if (_errorMessage != null) _buildErrorCard(),

            // Results
            if (_report != null) ...[
              _buildModelInfoCard(),
              const SizedBox(height: 16),
              _buildInferenceTable(),
              const SizedBox(height: 16),
              _buildRamCard(),
              const SizedBox(height: 16),
              _buildBatteryCard(),
              const SizedBox(height: 20),
              _buildActionButtons(),
            ],

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  //  WIDGET BUILDERS
  // ────────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    // Show device from report if complete, else from pre-loaded info
    final deviceLine = _report?.deviceName ?? _preloadedDevice;
    final chipsetLine = _report?.chipset ?? _preloadedChipset;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8B7FD6), Color(0xFF6C5CE7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B7FD6).withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.science, color: Colors.white, size: 24),
              const SizedBox(width: 8),
              Text(
                'SHIKSHA AI',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Performance Benchmark',
            style: GoogleFonts.outfit(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'On-device SLM inference metrics evaluation',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: Colors.white70,
              height: 1.4,
            ),
          ),
          // Device info — visible before, during, and after benchmark
          if (deviceLine.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.white24, thickness: 0.5),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.smartphone, color: Colors.white54, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    deviceLine,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (chipsetLine.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.memory, color: Colors.white54, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      chipsetLine,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildRunButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        onPressed: _startBenchmark,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF8B7FD6),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 24),
        label: Text(
          'Run Benchmark',
          style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final progress = _totalSteps > 0 ? (_currentStep + 1) / _totalSteps : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Benchmarking...',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1A1A1A),
                ),
              ),
              TextButton(
                onPressed: _cancelBenchmark,
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(
                    color: const Color(0xFFEF4444),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: const Color(0xFFF3F4F6),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF8B7FD6),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _progressLabel,
            style: GoogleFonts.inter(fontSize: 14, color: Colors.grey[600]),
          ),
          const SizedBox(height: 4),
          Text(
            '${(progress * 100).toStringAsFixed(0)}% complete',
            style: GoogleFonts.inter(fontSize: 12, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFE4E4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFEF4444)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _errorMessage!,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: const Color(0xFFEF4444),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelInfoCard() {
    final r = _report!;
    return _card(
      title: 'Model Info',
      icon: Icons.dns_rounded,
      children: [
        _metricRow('Device', r.deviceName),
        _metricRow('Chipset', r.chipset),
        _metricRow('Android', r.androidVersion),
        _metricRow('System RAM', '${r.totalRamMb} MB'),
        const Divider(height: 20),
        _metricRow('GGUF File Size', '${r.ggufSizeGb.toStringAsFixed(2)} GB'),
        _metricRow(
          'Model Load Time',
          '${(r.modelLoadTimeMs / 1000).toStringAsFixed(1)}s (${r.modelLoadTimeMs}ms)',
        ),
      ],
    );
  }

  Widget _buildInferenceTable() {
    final r = _report!;
    final avgs = r.averagesByPrompt;
    final labels = avgs.keys.toList();

    // Calculate overall averages for TTFT and TPS ratings
    final overallTtft = avgs.values.isEmpty
        ? 0
        : (avgs.values.map((a) => a.avgTtftMs).reduce((a, b) => a + b) /
                  avgs.values.length)
              .round();
    final overallTps = avgs.values.isEmpty
        ? 0.0
        : avgs.values.map((a) => a.avgTps).reduce((a, b) => a + b) /
              avgs.values.length;

    return _card(
      title: 'Inference Performance',
      icon: Icons.speed,
      subtitle: 'Average of ${BenchmarkService.runsPerPrompt} runs per prompt',
      children: [
        // Overall ratings
        Row(
          children: [
            Expanded(
              child: _ratingChip(
                'TTFT: ${_ttftRating(overallTtft)}',
                _ttftColor(overallTtft),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ratingChip(
                'TPS: ${_tpsRating(overallTps)}',
                _tpsColor(overallTps),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Table
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 36,
            columnSpacing: 16,
            headingTextStyle: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF6B7280),
            ),
            dataTextStyle: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF1A1A1A),
            ),
            columns: [
              const DataColumn(label: Text('Metric')),
              ...labels.map((l) => DataColumn(label: Text(l))),
            ],
            rows: [
              DataRow(
                cells: [
                  const DataCell(Text('TTFT (ms)')),
                  ...labels.map(
                    (l) => DataCell(
                      Text(
                        '${avgs[l]!.avgTtftMs}',
                        style: TextStyle(color: _ttftColor(avgs[l]!.avgTtftMs)),
                      ),
                    ),
                  ),
                ],
              ),
              DataRow(
                cells: [
                  const DataCell(Text('TPS (tok/s)')),
                  ...labels.map(
                    (l) => DataCell(
                      Text(
                        avgs[l]!.avgTps.toStringAsFixed(1),
                        style: TextStyle(color: _tpsColor(avgs[l]!.avgTps)),
                      ),
                    ),
                  ),
                ],
              ),
              DataRow(
                cells: [
                  const DataCell(Text('Latency (ms)')),
                  ...labels.map(
                    (l) => DataCell(Text('${avgs[l]!.avgLatencyMs}')),
                  ),
                ],
              ),
              DataRow(
                cells: [
                  const DataCell(Text('Avg Tokens')),
                  ...labels.map((l) => DataCell(Text('${avgs[l]!.avgTokens}'))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRamCard() {
    final r = _report!;
    return _card(
      title: 'RAM Usage',
      icon: Icons.memory,
      children: [
        _metricRow('Baseline System RAM In-Use', '${r.baselineRamMb} MB'),
        _metricRow('System RAM After Load', '${r.modelLoadedRamInMb} MB'),
        _highlightRow(
          'Model Footprint (${r.usedMlock ? "mlock" : "mmap"})',
          '${r.modelFootprintMb} MB',
          const Color(0xFF8B7FD6),
        ),
        const Divider(height: 20),
        _metricRow('Peak Inference RAM Delta', '${r.peakRamMb} MB'),
        _highlightRow(
          'Inference Overhead (KV+Compute)',  // FIX 8: Updated label
          '${r.inferenceOverheadMb} MB',
          const Color(0xFF6C5CE7),
        ),
      ],
    );
  }

  Widget _buildBatteryCard() {
    final r = _report!;
    return _card(
      title: 'Battery',
      icon: Icons.battery_std,
      children: [
        _metricRow('Before', '${r.batteryBefore}%'),
        _metricRow('After', '${r.batteryAfter}%'),
        _highlightRow(
          'Drain During Benchmark',
          '${r.batteryDrain}%',
          r.batteryDrain > 5
              ? const Color(0xFFEF4444)
              : const Color(0xFF10B981),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _shareReport,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8B7FD6),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.share, size: 20),
            label: Text(
              'Share Report',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _report = null;
                _errorMessage = null;
              });
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: Color(0xFFD8D0F2)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF8B7FD6)),
            label: Text(
              'Run Again',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
                color: const Color(0xFF8B7FD6),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────────
  //  REUSABLE COMPONENTS
  // ────────────────────────────────────────────────────────────────────

  Widget _card({
    required String title,
    required IconData icon,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFFF3E8FF),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: const Color(0xFF8B7FD6), size: 18),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1A1A1A),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.grey[400],
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: GoogleFonts.inter(fontSize: 14, color: Colors.grey[600]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF1A1A1A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _highlightRow(String label, String value, Color color) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ratingChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/backtest_engine.dart';
import '../services/scrip_service.dart';
import '../services/storage_service.dart';
import '../strategies/dominance_breakout_strategy.dart';
import '../strategies/strategy_registry.dart';
import 'backtest_results_screen.dart';

class BacktestProgressScreen extends StatefulWidget {
  final String accessToken;
  final String clientId;
  final DateTime fromDate;
  final DateTime toDate;
  final String stockUniverseLabel;
  final List<int> securityIds;
  final Map<String, dynamic> params;

  /// Which strategy to backtest (registry key). Defaults to dominance for
  /// backward compatibility with older navigation paths.
  final String strategyType;

  /// 'static' (legacy fixed list) or a point-in-time index mode.
  final String universeMode;

  const BacktestProgressScreen({
    super.key,
    required this.accessToken,
    required this.clientId,
    required this.fromDate,
    required this.toDate,
    required this.stockUniverseLabel,
    required this.securityIds,
    required this.params,
    this.strategyType = 'dominance_breakout',
    this.universeMode = 'static',
  });

  @override
  State<BacktestProgressScreen> createState() => _BacktestProgressScreenState();
}

class _BacktestProgressScreenState extends State<BacktestProgressScreen> {
  BacktestEngine? _engine;
  String _phase = 'Starting...';
  int _completed = 0;
  int _total = 1;
  String _statusMessage = '';
  final List<String> _logs = [];
  bool _running = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Keep the screen ON for the whole run: with the display off, Android
    // (vivo/oppo ROMs especially) demotes the app out of the foreground state
    // and throttles/freezes the CPU — the backtest crawls or stalls. Released
    // in dispose() and as soon as the run ends, so normal use is unaffected.
    WakelockPlus.enable();
    _startBacktest();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _startBacktest() async {
    final strategy = StrategyRegistry.create(widget.strategyType) ??
        DominanceBreakoutStrategy();
    final scripService = ScripService();

    _engine = BacktestEngine(
      strategy: strategy,
      params: widget.params,
      securityIds: widget.securityIds,
      accessToken: widget.accessToken,
      clientId: widget.clientId,
      scripService: scripService,
      universeMode: widget.universeMode,
      onProgress: (phase, completed, total, message) {
        if (!mounted) return;
        setState(() {
          _phase = phase;
          _completed = completed;
          _total = total;
          _statusMessage = message;
        });
      },
      onLog: (msg) {
        if (!mounted) return;
        setState(() {
          _logs.add(msg);
          if (_logs.length > 100) _logs.removeAt(0);
        });
      },
    );

    try {
      final result = await _engine!.run(
        fromDate: widget.fromDate,
        toDate: widget.toDate,
        stockUniverseLabel: widget.stockUniverseLabel,
      );

      if (!mounted) return;

      // Save result
      await StorageService.saveBacktestResult(result);

      setState(() {
        _running = false;
        _done = true;
      });
      WakelockPlus.disable(); // run finished — let the screen sleep again

      // Navigate to results
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BacktestResultsScreen(result: result),
          ),
        );
      }
    } catch (e) {
      WakelockPlus.disable(); // failed run — release the screen too
      // Truthful run status + checkpoint survive: the Runs tab will show
      // "failed … data through <lastSimDate>" so only the remainder needs
      // re-running.
      await _engine?.markRunFailed('$e');
      if (!mounted) return;
      setState(() {
        _running = false;
        _statusMessage = 'Error: $e';
        _logs.add('FATAL: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? _completed / _total : 0.0;
    final phaseLabel = switch (_phase) {
      'download' => 'Downloading Data',
      'prepare' => 'Preparing',
      'simulate' => 'Simulating',
      _ => _phase,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Running Backtest'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Phase indicator — FittedBox scales the row down on narrow
            // screens so the three chips always fit without overflowing.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  _phaseChip('Download', _phase == 'download',
                      _phase == 'simulate' || _phase == 'prepare'),
                  const Icon(Icons.arrow_right, color: Colors.grey),
                  _phaseChip('Prepare', _phase == 'prepare',
                      _phase == 'simulate'),
                  const Icon(Icons.arrow_right, color: Colors.grey),
                  _phaseChip('Simulate', _phase == 'simulate', _done),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Current phase title
            Text(
              phaseLabel,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 12,
                backgroundColor: Colors.grey.shade300,
              ),
            ),
            const SizedBox(height: 8),

            // Progress text — status can be long (date · trades · P&L · chunk),
            // so let it take the remaining width and ellipsize.
            Row(
              children: [
                Expanded(
                  child: Text(
                    _statusMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Log area
            const Text('Activity Log',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  reverse: true,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final log = _logs[_logs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        log,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: log.contains('Error')
                              ? Colors.red.shade300
                              : Colors.green.shade300,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Cancel button
            if (_running)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _engine?.cancel();
                    setState(() {
                      _running = false;
                      _statusMessage = 'Cancelled';
                    });
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.stop, color: Colors.red),
                  label: const Text('Cancel',
                      style: TextStyle(color: Colors.red)),
                ),
              ),

            if (!_running && !_done)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _phaseChip(String label, bool active, bool completed) {
    return Chip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: active
              ? Colors.white
              : completed
                  ? Colors.green
                  : Colors.grey,
        ),
      ),
      backgroundColor: active
          ? Colors.blue
          : completed
              ? Colors.green.withValues(alpha: 0.15)
              : null,
      avatar: completed
          ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
          : active
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
    );
  }
}

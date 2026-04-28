import 'dart:async';
import 'package:flutter/material.dart';
import '../models/strategy_config_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/storage_service.dart';
import '../services/strategy_background_service.dart';
import 'strategy_history_screen.dart';

class StrategyDashboardScreen extends StatefulWidget {
  final StrategyConfigModel config;
  final String clientId;
  final String accessToken;

  const StrategyDashboardScreen({
    super.key,
    required this.config,
    required this.clientId,
    required this.accessToken,
  });

  @override
  State<StrategyDashboardScreen> createState() =>
      _StrategyDashboardScreenState();
}

class _StrategyDashboardScreenState extends State<StrategyDashboardScreen>
    with WidgetsBindingObserver {
  bool _isRunning = false;
  String _statusMessage = 'Ready to start';
  int _progress = 0;
  int _candidateCount = 0;
  int _activeStocks = 0;

  // Phase tracking: 0=idle, 1=loading, 2=premarket, 3=screening, 4=monitoring, 5=completed
  int _currentPhase = 0;

  // Candidates (dominance signals)
  final List<_CandidateInfo> _candidates = [];

  // Activity log
  final List<_ActivityEntry> _activity = [];
  final ScrollController _activityScrollCtrl = ScrollController();

  // Trades
  List<StrategyTradeModel> _trades = [];

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _seedFromBuffer();
    _listenToService();
    _loadTrades();
    _checkRunning();
  }

  void _seedFromBuffer() {
    // Activity log
    final past = StrategyBackgroundService.activityFor(widget.config.id);
    for (final r in past) {
      _addActivityFromRecord(r);
    }
    // Phase / status / progress / candidates
    final s = StrategyBackgroundService.sessionFor(widget.config.id);
    if (s.configId == widget.config.id) {
      _currentPhase = s.currentPhase;
      _statusMessage = s.statusMessage.isNotEmpty
          ? s.statusMessage
          : _statusMessage;
      _progress = s.progress;
      _candidateCount = s.candidateCount;
      _activeStocks = s.activeStocks;
      _candidates
        ..clear()
        ..addAll(s.candidates.map((c) => _CandidateInfo(
              symbol: c.symbol,
              entryPrice: c.entryPrice,
              stopLoss: c.stopLoss,
              time: c.time,
              status: c.status,
            )));
    }
  }

  void _addActivityFromRecord(StrategyActivityRecord r) {
    final IconData icon;
    final Color color;
    switch (r.type) {
      case 'signal':
        icon = Icons.candlestick_chart;
        color = Colors.orange;
      case 'trade_entry':
        icon = Icons.arrow_upward;
        color = Colors.green;
      case 'trade_sl_hit':
        icon = Icons.arrow_downward;
        color = Colors.red;
      case 'trade_target_hit':
        icon = Icons.star;
        color = Colors.green;
      case 'trade_eod_exit':
        icon = Icons.schedule;
        color = Colors.orange;
      case 'completed':
        icon = Icons.check_circle;
        color = Colors.blue;
      case 'error':
        icon = Icons.error;
        color = Colors.red;
      default:
        icon = Icons.info_outline;
        color = Colors.blue;
    }
    _activity.insert(0, _ActivityEntry(
      icon: icon,
      color: color,
      message: r.message,
      time: r.time,
    ));
    if (_activity.length > 100) _activity.removeLast();

    // Auto-scroll to top (newest entry)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_activityScrollCtrl.hasClients) {
        _activityScrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _subs) {
      sub.cancel();
    }
    _activityScrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkRunning();
    }
  }

  Future<void> _checkRunning() async {
    final activeConfigId = await StorageService.getActiveStrategy();
    if (activeConfigId != null && activeConfigId == widget.config.id) {
      final running = await StrategyBackgroundService.isRunning();
      if (running && mounted) {
        setState(() => _isRunning = true);
        return;
      }
    }
    // No active strategy or not this config — ensure stopped state
    if (mounted) setState(() => _isRunning = false);
  }

  Future<void> _loadTrades() async {
    final trades = await StorageService.loadStrategyTrades();
    if (mounted) {
      setState(() {
        _trades = trades
            .where((t) => t.strategyConfigId == widget.config.id)
            .toList();
      });
    }
  }

  void _listenToService() {
    // Activity entries (centrally buffered → survives widget rebuilds)
    _subs.add(StrategyBackgroundService.activityStream.listen((r) {
      if (r.configId != widget.config.id || !mounted) return;
      setState(() => _addActivityFromRecord(r));
    }));

    // Phase updates
    _subs.add(StrategyBackgroundService.onPhase.listen((event) {
      if (event == null || !mounted) return;
      final phase = event['phase'] as String? ?? '';
      final message = event['message'] as String? ?? '';

      setState(() {
        switch (phase) {
          case 'loading':
            _currentPhase = 1;
          case 'preparing':
            _currentPhase = 2;
          case 'prepared':
            _currentPhase = 2;
          case 'screening':
            _currentPhase = 3;
        }
        if (message.isNotEmpty) _statusMessage = message;
      });
    }));

    // Status updates
    _subs.add(StrategyBackgroundService.onUpdate.listen((event) {
      if (event == null || !mounted) return;
      final status = event['status'] as String?;
      final message = event['message'] as String? ?? '';
      final progress = event['progress'] as int?;
      final candidates = event['candidates'] as int?;
      final activeStocks = event['activeStocks'] as int?;

      setState(() {
        if (message.isNotEmpty) _statusMessage = message;
        if (progress != null) _progress = progress;
        if (candidates != null) _candidateCount = candidates;
        if (activeStocks != null) _activeStocks = activeStocks;

        // Detect phase from message content
        if (message.contains('Fetching') || message.contains('Waiting for')) {
          _currentPhase = 3;
        }
        if (message.contains('Monitoring LTP') || message.contains('candidates found')) {
          if (_candidateCount > 0) _currentPhase = 4;
        }

        if (status == 'running') {
          _isRunning = true;
        }

        if (status == 'stopped' || status == 'completed') {
          _isRunning = false;
          _progress = 0;
          _currentPhase = status == 'completed' ? 5 : 0;
          StorageService.setActiveStrategy(null);
        }

      });
    }));

    // Signals found (dominance candidates) — activity entry comes via activityStream
    _subs.add(StrategyBackgroundService.onSignal.listen((event) {
      if (event == null || !mounted) return;
      final symbol = event['symbol'] as String? ?? '';
      final entry = (event['entryPrice'] as num?)?.toDouble() ?? 0;
      final sl = (event['stopLoss'] as num?)?.toDouble() ?? 0;

      setState(() {
        _candidateCount++;
        _currentPhase = 4; // Move to monitoring phase
        _candidates.add(_CandidateInfo(
          symbol: symbol,
          entryPrice: entry,
          stopLoss: sl,
          time: DateTime.now(),
          status: 'Watching',
        ));
      });
    }));

    // Trade updates — activity entry comes via activityStream
    _subs.add(StrategyBackgroundService.onTrade.listen((event) {
      if (event == null || !mounted) return;
      final type = event['type'] as String? ?? '';
      final symbol = event['symbol'] as String? ?? '';

      if (type == 'entry') {
        setState(() {
          // Mark candidate as traded
          for (int i = 0; i < _candidates.length; i++) {
            if (_candidates[i].symbol == symbol && _candidates[i].status == 'Watching') {
              _candidates[i] = _candidates[i].copyWith(status: 'Traded');
              break;
            }
          }
        });
      }

      _loadTrades();
    }));

    // Completed — activity entry comes via activityStream
    _subs.add(StrategyBackgroundService.onCompleted.listen((event) {
      if (event == null || !mounted) return;
      StorageService.setActiveStrategy(null);
      setState(() {
        _isRunning = false;
        _currentPhase = 5;
      });
      _loadTrades();
    }));

    // Errors — activity entry comes via activityStream
    _subs.add(StrategyBackgroundService.onError.listen((_) {
      // No-op: the error message is captured centrally and surfaces in the
      // activity log. Keep the subscription so future error-specific UI
      // (snackbars, etc.) has a hook.
    }));
  }

  Future<void> _toggleStrategy() async {
    if (!_isRunning) {
      if (!widget.config.enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Strategy is paused. Enable it in config first.')),
        );
        return;
      }

      final started = await StrategyBackgroundService.startService(
        configId: widget.config.id,
        strategyType: widget.config.strategyType,
        configName: widget.config.name,
        isPaper: widget.config.paperTrading,
        clientId: widget.clientId,
        accessToken: widget.accessToken,
        configJson: widget.config.toJson(),
      );

      if (!mounted) return;
      if (started) {
        await StorageService.setActiveStrategy(widget.config.id);
        if (!mounted) return;
        setState(() {
          _isRunning = true;
          _currentPhase = 1;
          _statusMessage = 'Starting...';
          _activity.clear();
          _candidates.clear();
          _candidateCount = 0;
          _activeStocks = 0;
          _progress = 0;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start — allow notification permission'), backgroundColor: Colors.red),
        );
      }
    } else {
      await StrategyBackgroundService.stopService();
      await StorageService.setActiveStrategy(null);
      if (mounted) {
        setState(() {
          _isRunning = false;
          _currentPhase = 0;
          _statusMessage = 'Stopped by user';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.config.paperTrading ? 'Paper' : 'Live';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config.name),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Run History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StrategyHistoryScreen(configId: widget.config.id),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: widget.config.paperTrading
                  ? Colors.orange.withValues(alpha: 0.15)
                  : Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: widget.config.paperTrading ? Colors.orange : Colors.green,
              ),
            ),
            child: Text(
              mode,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: widget.config.paperTrading ? Colors.orange : Colors.green,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Header with START/STOP ────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isRunning
                    ? [const Color(0xFF2E7D32), const Color(0xFF66BB6A)]
                    : [const Color(0xFF1565C0), const Color(0xFF42A5F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              children: [
                // Status
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isRunning) ...[
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                if (_isRunning && _progress > 0) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress / 100,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                      minHeight: 6,
                    ),
                  ),
                ],

                const SizedBox(height: 14),

                // START / STOP button
                SizedBox(
                  width: 180,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRunning ? Colors.red : Colors.white,
                      foregroundColor: _isRunning ? Colors.white : Colors.blue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                      elevation: 4,
                    ),
                    onPressed: _toggleStrategy,
                    icon: Icon(
                      _isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      size: 24,
                    ),
                    label: Text(
                      _isRunning ? 'STOP' : 'START',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Phase Indicator ────────────────────────────────────────
          if (_isRunning || _currentPhase == 5) _buildPhaseIndicator(),

          // ── Stats row ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _infoChip('Stocks', '${widget.config.securityIds.length}', Colors.blue),
                const SizedBox(width: 6),
                _infoChip('Active', '$_activeStocks', Colors.teal),
                const SizedBox(width: 6),
                _infoChip('Candidates', '$_candidateCount', Colors.orange),
                const SizedBox(width: 6),
                _infoChip('Trades', '${_trades.length}', Colors.green),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── Candidates section (dominance signals) ─────────────────
          if (_candidates.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.candlestick_chart, size: 18, color: Colors.orange),
                  const SizedBox(width: 6),
                  const Text('Candidates', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const Spacer(),
                  Text('${_candidates.length} found',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            SizedBox(
              height: 72,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _candidates.length,
                itemBuilder: (context, i) => _buildCandidateCard(_candidates[i]),
              ),
            ),
            const Divider(height: 1),
          ],

          // ── Trades section (if any) ──────────────────────────────
          if (_trades.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long, size: 18, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text('Trades', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const Spacer(),
                  Text(
                    'P&L: Rs ${_trades.fold<double>(0, (sum, t) => sum + t.pnl).toStringAsFixed(0)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _trades.fold<double>(0, (sum, t) => sum + t.pnl) >= 0
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _trades.length,
                itemBuilder: (context, i) {
                  final trade = _trades[i];
                  final isWin = trade.pnl > 0;
                  return Container(
                    width: 150,
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (isWin ? Colors.green : Colors.red).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (isWin ? Colors.green : Colors.red).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(isWin ? Icons.trending_up : Icons.trending_down,
                                size: 14, color: isWin ? Colors.green : Colors.red),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(trade.symbol,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('Qty: ${trade.quantity} @ ${trade.entryPrice.toStringAsFixed(1)}',
                            style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        Text(
                          'P&L: Rs ${trade.pnl.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isWin ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
          ],

          // ── Activity log ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 18, color: Colors.grey),
                const SizedBox(width: 6),
                const Text('Activity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                Text('${_activity.length} events',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          Expanded(
            child: _activity.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.auto_graph, size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        const Text('Press START to begin', style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 4),
                        Text(
                          'Signals, trades, and logs will appear here',
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _activityScrollCtrl,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _activity.length,
                    itemBuilder: (context, i) {
                      final entry = _activity[i];
                      final time =
                          '${entry.time.hour.toString().padLeft(2, "0")}:${entry.time.minute.toString().padLeft(2, "0")}:${entry.time.second.toString().padLeft(2, "0")}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(entry.icon, size: 16, color: entry.color),
                            const SizedBox(width: 8),
                            Text(time,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500,
                                    fontFamily: 'monospace')),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(entry.message,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Phase Indicator Widget ───────────────────────────────────────────

  Widget _buildPhaseIndicator() {
    // Phases: 1=Loading, 2=Pre-Market, 3=Screening, 4=Monitoring, 5=Completed
    const phases = [
      (icon: Icons.download, label: 'Load'),
      (icon: Icons.history, label: 'Pre-Mkt'),
      (icon: Icons.search, label: 'Screen'),
      (icon: Icons.trending_up, label: 'Monitor'),
      (icon: Icons.check_circle, label: 'Done'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      color: Colors.grey.shade100,
      child: Row(
        children: List.generate(phases.length, (i) {
          final phaseIndex = i + 1; // 1-based
          final isDone = _currentPhase > phaseIndex;
          final isActive = _currentPhase == phaseIndex;
          final isUpcoming = _currentPhase < phaseIndex;

          final color = isDone
              ? Colors.green
              : isActive
                  ? Colors.blue
                  : Colors.grey.shade400;

          return Expanded(
            child: Row(
              children: [
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: isDone ? Colors.green : Colors.grey.shade300,
                    ),
                  ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive
                            ? Colors.blue.withValues(alpha: 0.15)
                            : isDone
                                ? Colors.green.withValues(alpha: 0.15)
                                : Colors.grey.withValues(alpha: 0.08),
                        border: Border.all(color: color, width: isActive ? 2 : 1),
                      ),
                      child: Icon(
                        isDone ? Icons.check : phases[i].icon,
                        size: 14,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      phases[i].label,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                        color: isUpcoming ? Colors.grey : color,
                      ),
                    ),
                  ],
                ),
                if (i < phases.length - 1 && i == 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: _currentPhase > phaseIndex ? Colors.green : Colors.grey.shade300,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ── Candidate Card ───────────────────────────────────────────────────

  Widget _buildCandidateCard(_CandidateInfo c) {
    final isTraded = c.status == 'Traded';
    final color = isTraded ? Colors.green : Colors.orange;
    final time = '${c.time.hour.toString().padLeft(2, "0")}:${c.time.minute.toString().padLeft(2, "0")}';

    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(isTraded ? Icons.check_circle : Icons.candlestick_chart,
                  size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(c.symbol,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Entry: ${c.entryPrice.toStringAsFixed(1)}  SL: ${c.stopLoss.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
          Text(
            '$time  ${c.status}',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}

class _CandidateInfo {
  final String symbol;
  final double entryPrice;
  final double stopLoss;
  final DateTime time;
  final String status; // 'Watching', 'Traded', 'Expired'

  const _CandidateInfo({
    required this.symbol,
    required this.entryPrice,
    required this.stopLoss,
    required this.time,
    required this.status,
  });

  _CandidateInfo copyWith({String? status}) => _CandidateInfo(
        symbol: symbol,
        entryPrice: entryPrice,
        stopLoss: stopLoss,
        time: time,
        status: status ?? this.status,
      );
}

class _ActivityEntry {
  final IconData icon;
  final Color color;
  final String message;
  final DateTime time;

  const _ActivityEntry({
    required this.icon,
    required this.color,
    required this.message,
    required this.time,
  });
}

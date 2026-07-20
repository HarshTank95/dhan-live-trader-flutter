import 'dart:async';
import 'package:flutter/material.dart';
import '../models/strategy_config_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/storage_service.dart';
import '../services/strategy_background_service.dart';
import '../theme/app_theme.dart';
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

  // Trades persisted by the engine (storage; end-of-run for some strategies)
  List<StrategyTradeModel> _trades = [];

  // Live session trades — maintained centrally from trade_update events, so
  // position cards appear the moment ANY strategy enters a trade.
  List<StrategySessionTrade> _sessionTrades = [];

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
      _sessionTrades = s.trades;
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
        color = AppColors.warn;
      case 'trade_entry':
        icon = Icons.arrow_upward;
        color = AppColors.up;
      case 'trade_sl_hit':
        icon = Icons.arrow_downward;
        color = AppColors.down;
      case 'trade_target_hit':
        icon = Icons.star;
        color = AppColors.up;
      case 'trade_eod_exit':
        icon = Icons.schedule;
        color = AppColors.warn;
      case 'completed':
        icon = Icons.check_circle;
        color = AppColors.accent;
      case 'error':
        icon = Icons.error_outline;
        color = AppColors.down;
      default:
        icon = Icons.info_outline;
        color = AppColors.textFaint;
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
    } else if (state == AppLifecycleState.paused) {
      // Force pending activity / session writes to disk now so a swipe-away
      // within the 500ms debounce doesn't drop recent events.
      StrategyBackgroundService.flushNow();
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
    final today = DateTime.now();
    if (mounted) {
      setState(() {
        _trades = trades
            .where((t) => t.strategyConfigId == widget.config.id)
            .where((t) =>
                t.entryTime != null &&
                t.entryTime!.year == today.year &&
                t.entryTime!.month == today.month &&
                t.entryTime!.day == today.day)
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
      // Optional explicit phase (1=Load 2=Pre-Mkt 3=Screen 4=Monitor 5=Done).
      // Strategies that send it (ORB live) drive the stepper directly;
      // others keep the message-sniffing fallback below.
      final phase = event['phase'] as int?;

      setState(() {
        if (message.isNotEmpty) _statusMessage = message;
        if (progress != null) _progress = progress;
        if (candidates != null) _candidateCount = candidates;
        if (activeStocks != null) _activeStocks = activeStocks;

        if (phase != null) {
          _currentPhase = phase;
        } else {
          // Detect phase from message content
          if (message.contains('Fetching') || message.contains('Waiting for')) {
            _currentPhase = 3;
          }
          if (message.contains('Monitoring LTP') ||
              message.contains('candidates found')) {
            if (_candidateCount > 0) _currentPhase = 4;
          }
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

      setState(() {
        // Session trades are maintained centrally (bg service wires first) —
        // re-pull the snapshot so position cards update live.
        _sessionTrades =
            StrategyBackgroundService.sessionFor(widget.config.id).trades;
        if (type == 'entry') {
          // Mark candidate as traded
          for (int i = 0; i < _candidates.length; i++) {
            if (_candidates[i].symbol == symbol &&
                _candidates[i].status == 'Watching') {
              _candidates[i] = _candidates[i].copyWith(status: 'Traded');
              break;
            }
          }
        }
      });

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
          _sessionTrades = [];
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
    final sessionPnl = _sessionTrades.fold<double>(0, (a, t) => a + t.pnl);
    final tradeCount =
        _sessionTrades.isNotEmpty ? _sessionTrades.length : _trades.length;
    final tradesPnl = _sessionTrades.isNotEmpty
        ? sessionPnl
        : _trades.fold<double>(0, (s, t) => s + t.pnl);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, size: 22),
            tooltip: 'Run History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StrategyHistoryScreen(configId: widget.config.id),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: widget.config.paperTrading
                    ? const Color(0x24FFFFFF)
                    : AppColors.warn.withValues(alpha: 0.5),
              ),
              color: widget.config.paperTrading
                  ? Colors.transparent
                  : AppColors.warn.withValues(alpha: 0.08),
            ),
            child: Text(
              mode.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: widget.config.paperTrading
                    ? AppColors.textMuted
                    : AppColors.warn,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // ── Header with START/STOP ────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.hairline)),
            ),
            child: Column(
              children: [
                // Status line
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isRunning) ...[
                      const SizedBox(
                        width: 13, height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            fontFeatures: [FontFeature.tabularFigures()]),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                if (_isRunning && _progress > 0) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _progress / 100,
                      backgroundColor: AppColors.surfaceRaised,
                      valueColor:
                          const AlwaysStoppedAnimation(AppColors.accent),
                      minHeight: 4,
                    ),
                  ),
                ],

                const SizedBox(height: 12),

                // START / STOP button
                SizedBox(
                  width: 170,
                  height: 42,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          _isRunning ? AppColors.down : AppColors.accent,
                      foregroundColor: const Color(0xFF0B0D10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _toggleStrategy,
                    icon: Icon(
                      _isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      size: 20,
                    ),
                    label: Text(
                      _isRunning ? 'STOP' : 'START',
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2),
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
                _infoChip('Stocks', '${widget.config.securityIds.length}',
                    AppColors.textPrimary),
                const SizedBox(width: 6),
                _infoChip('Active', '$_activeStocks', AppColors.textPrimary),
                const SizedBox(width: 6),
                _infoChip(
                    'Candidates',
                    '$_candidateCount',
                    _candidateCount > 0
                        ? AppColors.warn
                        : AppColors.textPrimary),
                const SizedBox(width: 6),
                _infoChip(
                    'Trades',
                    '$tradeCount',
                    tradeCount == 0
                        ? AppColors.textPrimary
                        : tradesPnl >= 0
                            ? AppColors.up
                            : AppColors.down),
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
                  const Icon(Icons.candlestick_chart,
                      size: 16, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  const Text('Candidates',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const Spacer(),
                  Text('${_candidates.length} found',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textFaint)),
                ],
              ),
            ),
            SizedBox(
              height: 106,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                itemCount: _candidates.length,
                itemBuilder: (context, i) => _buildCandidateCard(_candidates[i]),
              ),
            ),
            const Divider(height: 1),
          ],

          // ── Positions (live session trades, any strategy shape) ──────
          if (_sessionTrades.isNotEmpty || _trades.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.work_outline,
                      size: 16, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  const Text('Positions',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const Spacer(),
                  Text(
                    '${tradesPnl >= 0 ? '+' : '-'}₹${AppFmt.inr(tradesPnl.abs())}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: tradesPnl > 0
                          ? AppColors.up
                          : tradesPnl < 0
                              ? AppColors.down
                              : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 96,
              child: _sessionTrades.isNotEmpty
                  ? ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      itemCount: _sessionTrades.length,
                      itemBuilder: (context, i) =>
                          _sessionTradeCard(_sessionTrades[i]),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      itemCount: _trades.length,
                      itemBuilder: (context, i) =>
                          _storedTradeCard(_trades[i]),
                    ),
            ),
            const Divider(height: 1),
          ],

          // ── Activity log ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.list_alt,
                    size: 16, color: AppColors.textMuted),
                const SizedBox(width: 6),
                const Text('Activity',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                Text('${_activity.length} events',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textFaint)),
              ],
            ),
          ),
          Expanded(
            child: _activity.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.auto_graph,
                            size: 48, color: AppColors.textFaint),
                        const SizedBox(height: 12),
                        const Text('Press START to begin',
                            style: TextStyle(color: AppColors.textMuted)),
                        const SizedBox(height: 4),
                        const Text(
                          'Signals, trades, and logs will appear here',
                          style: TextStyle(
                              color: AppColors.textFaint, fontSize: 12),
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
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(entry.icon, size: 14, color: entry.color),
                            const SizedBox(width: 8),
                            Text(time,
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.textFaint,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ])),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(entry.message,
                                  style: const TextStyle(fontSize: 12.5),
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        children: List.generate(phases.length, (i) {
          final phaseIndex = i + 1; // 1-based
          final isDone = _currentPhase > phaseIndex;
          final isActive = _currentPhase == phaseIndex;
          final isUpcoming = _currentPhase < phaseIndex;

          final color = isDone
              ? AppColors.up
              : isActive
                  ? AppColors.accent
                  : AppColors.textFaint;

          return Expanded(
            child: Row(
              children: [
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: isDone ? AppColors.up : AppColors.surfaceRaised,
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
                            ? AppColors.accentDim
                            : isDone
                                ? AppColors.up.withValues(alpha: 0.12)
                                : AppColors.surface,
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
                        color: isUpcoming ? AppColors.textFaint : color,
                      ),
                    ),
                  ],
                ),
                if (i < phases.length - 1 && i == 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: _currentPhase > phaseIndex
                          ? AppColors.up
                          : AppColors.surfaceRaised,
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
    final color = isTraded ? AppColors.up : AppColors.accent;
    final time = '${c.time.hour.toString().padLeft(2, "0")}:${c.time.minute.toString().padLeft(2, "0")}';

    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isTraded
              ? AppColors.hairline
              : AppColors.accent.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(isTraded ? Icons.check_circle : Icons.candlestick_chart,
                  size: 13, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(c.symbol,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text('Break ▲${c.entryPrice.toStringAsFixed(1)}',
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontFeatures: [FontFeature.tabularFigures()])),
          Text('SL: ${c.stopLoss.toStringAsFixed(1)}',
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontFeatures: [FontFeature.tabularFigures()])),
          Text(
            '$time  ${c.status}',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(String label, String value, Color valueColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textMuted)),
            const SizedBox(height: 3),
            Text(value,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: valueColor)),
          ],
        ),
      ),
    );
  }

  // ── Position cards ───────────────────────────────────────────────────

  Widget _sessionTradeCard(StrategySessionTrade t) {
    final open = t.isOpen;
    final pnlColor = t.pnl > 0
        ? AppColors.up
        : t.pnl < 0
            ? AppColors.down
            : AppColors.textMuted;
    final statusLabel = switch (t.status) {
      'sl_hit' => 'SL HIT',
      'target_hit' => 'TARGET',
      'eod_exit' => 'EOD EXIT',
      _ => 'OPEN',
    };
    final hm =
        '${t.entryTime.hour.toString().padLeft(2, '0')}:${t.entryTime.minute.toString().padLeft(2, '0')}';

    return Container(
      width: 172,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: open
              ? AppColors.accent.withValues(alpha: 0.45)
              : AppColors.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(t.symbol,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              if (open)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentDim,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('OPEN',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: AppColors.accent)),
                )
              else
                Text(
                  '${t.pnl >= 0 ? '+' : '-'}₹${AppFmt.inr(t.pnl.abs())}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: pnlColor),
                ),
            ],
          ),
          Text('BUY ${t.quantity} @ ${AppFmt.inr(t.entryPrice)}',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                  fontFeatures: [FontFeature.tabularFigures()])),
          Text(
            open
                ? 'SL ${AppFmt.inr(t.stopLoss)} · since $hm'
                : '$statusLabel @ ${AppFmt.inr(t.exitPrice)}',
            style: const TextStyle(
                fontSize: 10.5,
                color: AppColors.textFaint,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }

  Widget _storedTradeCard(StrategyTradeModel trade) {
    final pnlColor = trade.pnl > 0
        ? AppColors.up
        : trade.pnl < 0
            ? AppColors.down
            : AppColors.textMuted;
    return Container(
      width: 172,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(trade.symbol,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              Text(
                '${trade.pnl >= 0 ? '+' : '-'}₹${AppFmt.inr(trade.pnl.abs())}',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: pnlColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Qty ${trade.quantity} @ ${AppFmt.inr(trade.entryPrice)}',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
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

import 'package:candlesticks/candlesticks.dart';
import 'package:uuid/uuid.dart';

import '../models/backtest_result_model.dart';
import '../models/candle_stats_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/app_logger.dart';
import '../services/candle_repository.dart';
import '../services/run_logger.dart';
import '../services/scrip_service.dart';
import '../strategies/base_strategy.dart';

/// Progress callback for backtest phases.
typedef BacktestProgressCallback = void Function(
    String phase, int completed, int total, String message);

/// Generic backtest engine — works with any [BaseStrategy] implementation.
///
/// Workflow per trading day:
///   1. Compute stats from prior N days of cached candles
///   2. Progressive volume elimination (same as live engine)
///   3. Call strategy.scan() for dominance detection
///   4. Walk subsequent candles to simulate breakout
///   5. Walk further candles to simulate SL/target/EOD exit
///   6. Aggregate per-day and overall results
class BacktestEngine {
  final BaseStrategy strategy;
  final Map<String, dynamic> params;
  final List<int> securityIds;
  final String accessToken;
  final String clientId;
  final ScripService scripService;
  final BacktestProgressCallback? onProgress;
  final void Function(String message)? onLog;

  bool _cancelled = false;
  // Per-backtest structured logger. Same JSONL format and viewer as live
  // engine runs — surfaces in the Log Viewer "Runs" tab with kind=backtest.
  RunLoggerSession? _runLog;

  BacktestEngine({
    required this.strategy,
    required this.params,
    required this.securityIds,
    required this.accessToken,
    required this.clientId,
    required this.scripService,
    this.onProgress,
    this.onLog,
  });

  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;

  /// Run backtest over the given date range. Returns full results.
  Future<BacktestResultModel> run({
    required DateTime fromDate,
    required DateTime toDate,
    required String stockUniverseLabel,
  }) async {
    final stopwatch = Stopwatch()..start();
    _cancelled = false;

    final historicalDays = (params['historicalDays'] as num?)?.toInt() ?? 10;

    // Open a per-backtest log file. Same JSONL format as live runs — viewable
    // from the Log Viewer "Runs" tab so devs can replay any past simulation.
    final now = DateTime.now();
    final startTimeStr =
        '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}';
    final runDate = _fmt(now);
    // Distinguish multiple backtest runs on the same day by appending the
    // strategy type + a short timestamp suffix.
    final runId =
        'bt_${runDate}_${strategy.type}_${now.millisecondsSinceEpoch ~/ 1000 % 100000}';
    _runLog = await RunLogger.startRun(
      runId: runId,
      date: runDate,
      configId: 'backtest_${strategy.type}',
      configName: '${strategy.displayName} (${_fmt(fromDate)} → ${_fmt(toDate)})',
      strategyType: strategy.type,
      paperTrading: true,
      startTime: startTimeStr,
      kind: 'backtest',
    );

    // ── Phase 1: Download all candle data ──────────────────────────
    onProgress?.call('download', 0, securityIds.length, 'Starting data download...');
    _log('═══ BACKTEST STARTING ═══');
    _log('Strategy: ${strategy.displayName}');
    _log('Period: ${_fmt(fromDate)} → ${_fmt(toDate)}');
    _log('Universe: $stockUniverseLabel (${securityIds.length} stocks)');
    _log('Risk: ₹${params['fixedStopLoss']} | Target: ₹${params['fixedTarget']} | Max trades/day: ${params['maxTradesPerDay']}');
    _log('Downloading candle data for ${securityIds.length} stocks...');
    _runLog?.info('Backtest', 'Backtest started', {
      'strategy': strategy.type,
      'fromDate': _fmt(fromDate),
      'toDate': _fmt(toDate),
      'universe': stockUniverseLabel,
      'universeSize': securityIds.length,
      'historicalDays': historicalDays,
      'params': params,
    });

    // We need candles from (fromDate - historicalDays - buffer) to toDate
    // The extra days are for computing stats (avgVolume, avgCandleSize)
    final dataStartDate = fromDate.subtract(Duration(days: historicalDays + 20));

    final allCandleData = await CandleRepository.instance.bulkFetch(
      securityIds: securityIds,
      fromDate: dataStartDate,
      toDate: toDate,
      interval: params['candleInterval'] as String? ?? '5',
      accessToken: accessToken,
      clientId: clientId,
      onProgress: (completed, total, status) {
        onProgress?.call('download', completed, total, status);
      },
      onLog: (msg) => _log(msg),
      isCancelled: () => _cancelled,
    );

    if (_cancelled) {
      final r = _emptyResult(fromDate, toDate, stockUniverseLabel, stopwatch);
      await _closeBacktestLog(r, 'cancelled');
      return r;
    }

    _log('Download complete. Got data for ${allCandleData.length} stocks.');

    // ── Phase 2: Group candles by date per stock ───────────────────
    onProgress?.call('prepare', 0, 1, 'Organizing candle data...');

    // Build per-stock, per-date candle map
    final stockDateCandles = <int, Map<String, List<Candle>>>{};
    for (final entry in allCandleData.entries) {
      final secId = entry.key;
      final candles = entry.value;
      final byDate = <String, List<Candle>>{};
      for (final c in candles) {
        final dateStr = _fmt(c.date);
        byDate.putIfAbsent(dateStr, () => []).add(c);
      }
      stockDateCandles[secId] = byDate;
    }

    // ── Phase 3: Collect all trading days in range ─────────────────
    final tradingDays = <String>[];
    var d = fromDate;
    while (!d.isAfter(toDate)) {
      if (d.weekday != DateTime.saturday && d.weekday != DateTime.sunday) {
        final dateStr = _fmt(d);
        // Only include days where at least some stocks have data
        final hasData = stockDateCandles.values.any((m) => m.containsKey(dateStr));
        if (hasData) tradingDays.add(dateStr);
      }
      d = d.add(const Duration(days: 1));
    }

    _log('Trading days in range: ${tradingDays.length}');

    // ── Phase 4: Simulate each trading day ─────────────────────────
    final dayResults = <BacktestDayResult>[];

    for (int dayIdx = 0; dayIdx < tradingDays.length; dayIdx++) {
      if (_cancelled) break;

      final dateStr = tradingDays[dayIdx];
      onProgress?.call(
        'simulate',
        dayIdx + 1,
        tradingDays.length,
        'Simulating $dateStr (${dayIdx + 1}/${tradingDays.length})',
      );

      final dayResult = _simulateDay(
        dateStr: dateStr,
        stockDateCandles: stockDateCandles,
        historicalDays: historicalDays,
      );

      dayResults.add(dayResult);

      // Yield to event loop so UI stays responsive
      await Future.delayed(Duration.zero);

      // Log day summary if it had activity
      if (dayResult.dominanceSignals > 0 || dayResult.tradesEntered > 0) {
        _log('$dateStr: ${dayResult.dominanceSignals} signals, '
            '${dayResult.tradesEntered} trades, '
            'P&L: ₹${dayResult.dayPnl.toStringAsFixed(0)}');
      }
      _runLog?.info('Backtest', 'Day complete', {
        'date': dateStr,
        'stocksScanned': dayResult.stocksScanned,
        'stocksAfterElim': dayResult.stocksAfterElimination,
        'signals': dayResult.dominanceSignals,
        'trades': dayResult.tradesEntered,
        'wins': dayResult.wins,
        'losses': dayResult.losses,
        'dayPnl': dayResult.dayPnl,
      });
    }

    // ── Phase 5: Aggregate results ─────────────────────────────────
    stopwatch.stop();

    int totalSignals = 0;
    int totalTrades = 0;
    int wins = 0;
    int losses = 0;
    double totalPnl = 0;
    int daysWithSignals = 0;
    int daysWithTrades = 0;

    double peakPnl = 0;
    double maxDrawdown = 0;
    double cumPnl = 0;

    for (final day in dayResults) {
      totalSignals += day.dominanceSignals;
      totalTrades += day.tradesEntered;
      wins += day.wins;
      losses += day.losses;
      totalPnl += day.dayPnl;
      if (day.dominanceSignals > 0) daysWithSignals++;
      if (day.tradesEntered > 0) daysWithTrades++;

      cumPnl += day.dayPnl;
      if (cumPnl > peakPnl) peakPnl = cumPnl;
      final drawdown = peakPnl - cumPnl;
      if (drawdown > maxDrawdown) maxDrawdown = drawdown;
    }

    _log('═══ BACKTEST COMPLETE ═══');
    _log('Trading days: ${tradingDays.length} | Signals: $totalSignals | Trades: $totalTrades');
    _log('Wins: $wins | Losses: $losses | Win rate: ${totalTrades > 0 ? (wins / totalTrades * 100).toStringAsFixed(1) : 0}%');
    _log('Total P&L: ₹${totalPnl.toStringAsFixed(0)} | Max Drawdown: ₹${maxDrawdown.toStringAsFixed(0)}');
    _log('Duration: ${stopwatch.elapsed.inSeconds}s');

    final result = BacktestResultModel(
      strategyType: strategy.type,
      strategyName: strategy.displayName,
      params: Map.from(params),
      fromDate: fromDate,
      toDate: toDate,
      stockUniverseSize: securityIds.length,
      stockUniverseLabel: stockUniverseLabel,
      durationSeconds: stopwatch.elapsed.inSeconds,
      totalTradingDays: tradingDays.length,
      daysWithSignals: daysWithSignals,
      daysWithTrades: daysWithTrades,
      totalSignals: totalSignals,
      totalTrades: totalTrades,
      wins: wins,
      losses: losses,
      totalPnl: totalPnl,
      maxDrawdown: maxDrawdown,
      peakPnl: peakPnl,
      dayResults: dayResults,
    );
    await _closeBacktestLog(result, _cancelled ? 'cancelled' : 'completed');
    return result;
  }

  /// Finalize the backtest run log with summary stats. Safe to call multiple
  /// times — the underlying file write is idempotent.
  Future<void> _closeBacktestLog(BacktestResultModel r, String status) async {
    if (_runLog == null) return;
    final now = DateTime.now();
    final endTime =
        '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}';
    await _runLog!.close(
      status: status,
      endTime: endTime,
      signals: r.totalSignals,
      trades: r.totalTrades,
      totalStocks: r.stockUniverseSize,
      finalActiveStocks: r.stockUniverseSize,
      totalPnl: r.totalPnl,
    );
    _runLog = null;
  }

  // ── Per-Day Simulation ──────────────────────────────────────────────

  BacktestDayResult _simulateDay({
    required String dateStr,
    required Map<int, Map<String, List<Candle>>> stockDateCandles,
    required int historicalDays,
  }) {
    final minAbsoluteVolume =
        (params['minAbsoluteVolume'] as num?)?.toInt() ?? 5000;
    final maxTradesPerDay =
        (params['maxTradesPerDay'] as num?)?.toInt() ?? 2;

    // Step 1: Compute stats for each stock from prior days
    final stats = <int, CandleStatsModel>{};
    var activeIds = <int>[];

    for (final secId in securityIds) {
      final dateMap = stockDateCandles[secId];
      if (dateMap == null) continue;

      // Collect candles from prior trading days
      final priorCandles = <Candle>[];
      // Get all dates for this stock, sorted, before current day
      final allDates = dateMap.keys.where((d) => d.compareTo(dateStr) < 0).toList()
        ..sort();

      // Take last N days
      final startIdx =
          allDates.length > historicalDays ? allDates.length - historicalDays : 0;
      for (int i = startIdx; i < allDates.length; i++) {
        priorCandles.addAll(dateMap[allDates[i]]!);
      }

      if (priorCandles.isEmpty) continue;

      final avgVolume =
          priorCandles.fold<double>(0, (sum, c) => sum + c.volume) /
              priorCandles.length;
      final avgCandleSize =
          priorCandles.fold<double>(0, (sum, c) => sum + (c.high - c.low)) /
              priorCandles.length;
      final prevClose = priorCandles.last.close;

      final scrip = scripService.findById(secId);
      stats[secId] = CandleStatsModel(
        securityId: secId,
        symbol: scrip?.symbol ?? secId.toString(),
        avgCandleSize: avgCandleSize,
        avgVolume: avgVolume,
        prevClose: prevClose,
        totalCandles: priorCandles.length,
      );
      activeIds.add(secId);
    }

    final totalStocksScanned = activeIds.length;

    // Step 2: Get today's candles for active stocks
    final todayCandles = <int, List<Candle>>{};
    for (final secId in List.of(activeIds)) {
      final dateMap = stockDateCandles[secId];
      final candles = dateMap?[dateStr];
      if (candles == null || candles.isEmpty) {
        activeIds.remove(secId);
        continue;
      }
      todayCandles[secId] = candles;
    }

    // Step 3: Progressive volume elimination
    // Simulate screening intervals (9:20, 9:25, ..., scanEnd)
    final scanEndHour = (params['scanEndHour'] as num?)?.toInt() ?? 10;
    final scanEndMin = (params['scanEndMin'] as num?)?.toInt() ?? 0;
    final scanEndMinutes = scanEndHour * 60 + scanEndMin;
    final scanInterval = (params['scanIntervalMinutes'] as num?)?.toInt() ?? 5;

    // Build screening time slots (in minutes from midnight)
    final screeningSlots = <int>[];
    var slotMin = 9 * 60 + 20; // Start at 9:20
    while (slotMin <= scanEndMinutes) {
      screeningSlots.add(slotMin);
      slotMin += scanInterval;
    }

    final alreadySignalled = <int>{};
    final allSignals = <StrategySignalModel>[];
    int stocksAfterElimination = activeIds.length;

    // Per-day scan diagnostics — aggregated across all slots for the
    // WHY ZERO line at end-of-day.
    int dayScanSlots = 0;
    int dayStocksEvaluated = 0;
    int dayCandlesEvaluated = 0;
    final dayRejects = <String, int>{};

    for (final slot in screeningSlots) {
      // Eliminate stocks whose latest candle (up to this slot) has low volume
      final toRemove = <int>[];
      for (final secId in activeIds) {
        final candles = todayCandles[secId];
        if (candles == null || candles.isEmpty) {
          toRemove.add(secId);
          continue;
        }

        // Find the latest candle at or before this slot time
        final candlesUpToSlot = candles
            .where((c) => c.date.hour * 60 + c.date.minute <= slot)
            .toList();

        if (candlesUpToSlot.isEmpty) {
          toRemove.add(secId);
          continue;
        }

        final latestCandle = candlesUpToSlot.last;
        if (latestCandle.volume < minAbsoluteVolume) {
          toRemove.add(secId);
        }
      }

      activeIds.removeWhere((id) => toRemove.contains(id));
      stocksAfterElimination = activeIds.length;

      // Expire old signals: remove from alreadySignalled so stock can be re-screened
      // (matches live engine: _alreadySignalled.remove(signal.securityId) on expiry)
      // Note: keep signals in allSignals — Step 4 still checks for breakout within
      // each signal's [timestamp, expiryTime] window.
      for (final s in allSignals) {
        final expiryMin = s.expiryTime.hour * 60 + s.expiryTime.minute;
        if (expiryMin <= slot && alreadySignalled.contains(s.securityId)) {
          alreadySignalled.remove(s.securityId);
          _log('EXPIRED [$dateStr]: ${s.symbol} — signal expired, can be re-screened');
        }
      }

      // Scan for dominance (only from scanStart onwards)
      final scanStartHour = (params['scanStartHour'] as num?)?.toInt() ?? 9;
      final scanStartMin = (params['scanStartMin'] as num?)?.toInt() ?? 30;
      final scanStartMinutes = scanStartHour * 60 + scanStartMin;

      if (slot >= scanStartMinutes) {
        // Build candle map for active stocks only (candles up to this slot)
        final slotCandles = <int, List<Candle>>{};
        for (final secId in activeIds) {
          final candles = todayCandles[secId];
          if (candles == null) continue;
          final upToSlot = candles
              .where((c) => c.date.hour * 60 + c.date.minute <= slot)
              .toList();
          if (upToSlot.isNotEmpty) slotCandles[secId] = upToSlot;
        }

        ScanReport? lastReport;
        final slotLabel =
            '${(slot ~/ 60).toString().padLeft(2, "0")}:${(slot % 60).toString().padLeft(2, "0")}';
        final signals = strategy.scan(
          configId: 'backtest',
          stats: stats,
          todayCandles: slotCandles,
          params: params,
          scripService: scripService,
          alreadySignalled: alreadySignalled,
          onScanReport: (r) => lastReport = r,
          // Same forensic stream as the live engine. Lets devs replay a
          // backtest day side-by-side with a live JSONL and diff per-stock
          // outcomes when results disagree.
          onStockReject: (ev) => _runLog?.info(
            'Reject',
            '[$dateStr $slotLabel] ${ev.symbol} ${ev.rule} @${ev.candleTime.hour.toString().padLeft(2, "0")}:${ev.candleTime.minute.toString().padLeft(2, "0")}: ${ev.detail}',
            {
              ...ev.toJson(),
              'date': dateStr,
              'slot': slotLabel,
            },
          ),
        );

        // Per-slot structured SCAN summary into the backtest run log, same
        // format the live engine uses. Lets devs replay any past simulation
        // and pinpoint which rule eliminated stocks on a given day/slot.
        if (lastReport != null) {
          final r = lastReport!;
          dayScanSlots++;
          dayStocksEvaluated += r.stocksEvaluated;
          dayCandlesEvaluated += r.candlesInWindow;
          r.rejectCounts.forEach((rule, count) {
            dayRejects[rule] = (dayRejects[rule] ?? 0) + count;
          });
          _runLog?.info(
            'Scan',
            'SCAN [$dateStr $slotLabel] in=${r.stocksEvaluated} window=${r.candlesInWindow} signals=${signals.length}'
            '${r.topRejects(3).isEmpty ? "" : " | ${r.topRejects(3).join(" ")}"}',
            {
              'date': dateStr,
              'slot': slotLabel,
              'stocksEvaluated': r.stocksEvaluated,
              'candlesInWindow': r.candlesInWindow,
              'signals': signals.length,
              'rejectCounts': r.rejectCounts,
            },
          );
        }

        for (final signal in signals) {
          alreadySignalled.add(signal.securityId);

          // Fix timestamp & expiry for backtest context:
          // scan() uses DateTime.now() which is wrong in simulation.
          // Use the candle's actual time from the dominance candle data.
          final candleTime = DateTime.parse(dateStr).add(
            Duration(hours: slot ~/ 60, minutes: slot % 60),
          );
          signal.timestamp = candleTime;
          signal.expiryTime = candleTime.add(
            Duration(minutes: scanInterval),
          );

          allSignals.add(signal);
          final slotTime = '${(slot ~/ 60).toString().padLeft(2, '0')}:${(slot % 60).toString().padLeft(2, '0')}';
          final expiryTime = '${signal.expiryTime.hour.toString().padLeft(2, '0')}:${signal.expiryTime.minute.toString().padLeft(2, '0')}';
          _log('DOMINANCE [$dateStr $slotTime]: ${signal.symbol} Entry=${signal.entryPrice} SL=${signal.stopLoss} Window=$slotTime→$expiryTime');
        }
      }
    }

    // Step 4: Simulate breakouts and exits
    final trades = <StrategyTradeModel>[];
    final tradedSecIds = <int>{}; // prevent same stock being traded twice (matches live)
    int tradesPlaced = 0;

    for (final signal in allSignals) {
      if (tradesPlaced >= maxTradesPerDay) {
        _log('SKIP [$dateStr]: ${signal.symbol} — max trades ($maxTradesPerDay) reached');
        break;
      }

      // Live engine: once a stock has a breakout trade, it stays in _alreadySignalled
      // and can never be traded again that day
      if (tradedSecIds.contains(signal.securityId)) {
        _log('SKIP [$dateStr]: ${signal.symbol} — already traded today');
        continue;
      }

      final candles = todayCandles[signal.securityId];
      if (candles == null) continue;

      // Find candles AFTER the signal candle time but BEFORE expiry
      // Live strategy: signals expire at next scan interval boundary
      final signalMinute =
          signal.timestamp.hour * 60 + signal.timestamp.minute;
      final expiryMinute =
          signal.expiryTime.hour * 60 + signal.expiryTime.minute;
      final afterSignal = candles
          .where((c) {
            final m = c.date.hour * 60 + c.date.minute;
            return m > signalMinute && m <= expiryMinute;
          })
          .toList();

      // Check if any candle breaks above entry price before expiry
      StrategyTradeModel? trade;
      for (final candle in afterSignal) {
        if (candle.high > signal.entryPrice) {
          // Breakout detected — create trade
          trade = _createTrade(signal, candle);
          if (trade != null) {
            final brkTime = '${candle.date.hour.toString().padLeft(2, '0')}:${candle.date.minute.toString().padLeft(2, '0')}';
            _log('BREAKOUT [$dateStr $brkTime]: ${signal.symbol} High=${candle.high} > Entry=${signal.entryPrice} → Qty=${trade.quantity} SL=${trade.stopLoss} Target=${trade.target}');
            break;
          }
        }
      }

      if (trade == null) {
        final sigTime = '${signal.timestamp.hour.toString().padLeft(2, '0')}:${signal.timestamp.minute.toString().padLeft(2, '0')}';
        final expTime = '${signal.expiryTime.hour.toString().padLeft(2, '0')}:${signal.expiryTime.minute.toString().padLeft(2, '0')}';
        _log('NO BREAKOUT [$dateStr]: ${signal.symbol} Entry=${signal.entryPrice} Window=$sigTime→$expTime Candles=${afterSignal.length}');
        continue;
      }

      tradedSecIds.add(signal.securityId);

      // Simulate exit: walk candles after entry
      final entryMinute =
          trade.entryTime!.hour * 60 + trade.entryTime!.minute;
      final afterEntry = candles
          .where((c) => c.date.hour * 60 + c.date.minute > entryMinute)
          .toList();

      for (final candle in afterEntry) {
        // Conservative: if both SL and target hit in same candle, assume SL
        if (candle.low <= trade.stopLoss) {
          trade.status = TradeStatus.closed;
          trade.exitPrice = trade.stopLoss;
          trade.exitTime = candle.date;
          trade.outcome = TradeOutcome.stopLoss;
          _log('SL HIT [$dateStr]: ${trade.symbol} @ ${trade.stopLoss} P&L=₹${trade.pnl.toStringAsFixed(0)}');
          break;
        } else if (candle.high >= trade.target) {
          trade.status = TradeStatus.closed;
          trade.exitPrice = trade.target;
          trade.exitTime = candle.date;
          trade.outcome = TradeOutcome.target;
          _log('TARGET [$dateStr]: ${trade.symbol} @ ${trade.target} P&L=₹${trade.pnl.toStringAsFixed(0)}');
          break;
        }
      }

      // If still open at EOD, square off at last candle's close
      if (trade.status == TradeStatus.open && candles.isNotEmpty) {
        trade.status = TradeStatus.closed;
        trade.exitPrice = candles.last.close;
        trade.exitTime = candles.last.date;
        trade.outcome = TradeOutcome.endOfDay;
        _log('EOD EXIT [$dateStr]: ${trade.symbol} @ ${trade.exitPrice} P&L=₹${trade.pnl.toStringAsFixed(0)}');
      }

      trades.add(trade);
      tradesPlaced++;
    }

    // Aggregate day results
    final dayWins = trades.where((t) => t.pnl > 0).length;
    final dayLosses = trades.where((t) => t.pnl < 0).length;
    final dayPnl = trades.fold<double>(0, (sum, t) => sum + t.pnl);

    _log('DAY SUMMARY [$dateStr]: Scanned=$totalStocksScanned AfterElim=$stocksAfterElimination Signals=${allSignals.length} Trades=${trades.length} W=$dayWins L=$dayLosses PnL=₹${dayPnl.toStringAsFixed(0)}');

    // WHY ZERO per-day diagnostic in the run log (only when 0 signals).
    // Same rationale as the live engine: gives devs an at-a-glance reason
    // a backtest day produced nothing without grepping per-stock REJECT lines.
    if (allSignals.isEmpty && dayScanSlots > 0) {
      final sorted = dayRejects.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final totalRej = dayRejects.values.fold<int>(0, (sum, v) => sum + v);
      String reason;
      if (dayCandlesEvaluated == 0) {
        reason = 'No candles in scan window.';
      } else if (sorted.isEmpty) {
        reason = 'Window had candles but no rejects — logic gap.';
      } else {
        final top = sorted.first;
        final pct =
            totalRej > 0 ? (top.value * 100 / totalRej).round() : 0;
        reason = 'Dominant: ${top.key} (${top.value}×, $pct%)';
      }
      final avgStocks = dayScanSlots > 0
          ? (dayStocksEvaluated / dayScanSlots).round()
          : 0;
      _runLog?.warn('Diagnosis',
          'WHY ZERO [$dateStr]: $dayScanSlots slots × $avgStocks stocks avg = $dayCandlesEvaluated candle-checks. $reason', {
        'date': dateStr,
        'scanSlots': dayScanSlots,
        'avgStocksPerSlot': avgStocks,
        'candlesEvaluated': dayCandlesEvaluated,
        'aggregateRejects': dayRejects,
      });
    }

    return BacktestDayResult(
      date: dateStr,
      stocksScanned: totalStocksScanned,
      stocksAfterElimination: stocksAfterElimination,
      dominanceSignals: allSignals.length,
      tradesEntered: trades.length,
      wins: dayWins,
      losses: dayLosses,
      dayPnl: dayPnl,
      trades: trades,
    );
  }

  // ── Trade Creation ──────────────────────────────────────────────────

  StrategyTradeModel? _createTrade(
      StrategySignalModel signal, Candle breakoutCandle) {
    final fixedSL = (params['fixedStopLoss'] as num?)?.toDouble() ?? 500;
    final fixedTarget = (params['fixedTarget'] as num?)?.toDouble() ?? 2000;

    final entryPrice = signal.entryPrice;
    final slPrice = signal.stopLoss;
    final riskPerShare = entryPrice - slPrice;

    if (riskPerShare <= 0) return null;

    final quantity = (fixedSL / riskPerShare).floor();
    if (quantity <= 0) return null;

    final targetPrice = entryPrice + (fixedTarget / quantity);

    return StrategyTradeModel(
      id: const Uuid().v4(),
      strategyConfigId: 'backtest',
      signalId: signal.id,
      securityId: signal.securityId,
      symbol: signal.symbol,
      status: TradeStatus.open,
      isPaperTrade: true,
      entryPrice: entryPrice,
      quantity: quantity,
      entryTime: breakoutCandle.date,
      stopLoss: slPrice,
      target: targetPrice,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  BacktestResultModel _emptyResult(
      DateTime from, DateTime to, String label, Stopwatch sw) {
    sw.stop();
    return BacktestResultModel(
      strategyType: strategy.type,
      strategyName: strategy.displayName,
      params: Map.from(params),
      fromDate: from,
      toDate: to,
      stockUniverseSize: securityIds.length,
      stockUniverseLabel: label,
      durationSeconds: sw.elapsed.inSeconds,
      totalTradingDays: 0,
      daysWithSignals: 0,
      daysWithTrades: 0,
      totalSignals: 0,
      totalTrades: 0,
      wins: 0,
      losses: 0,
      totalPnl: 0,
      maxDrawdown: 0,
      peakPnl: 0,
      dayResults: [],
    );
  }

  void _log(String msg) {
    onLog?.call(msg);
    AppLogger.info('Backtest', msg);
    // Mirror to the per-backtest run log so the JSONL file is a complete
    // forensic record (matches the live engine behavior).
    _runLog?.info('Backtest', msg);
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

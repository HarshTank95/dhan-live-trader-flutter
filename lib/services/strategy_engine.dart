import 'dart:async';
import 'dart:convert';

import 'package:candlesticks/candlesticks.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/candle_stats_model.dart';
import '../models/daily_run_summary_model.dart';
import '../models/strategy_config_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/app_logger.dart';
import '../services/candle_sanitizer.dart';
import '../services/rate_limiter.dart';
import '../services/run_logger.dart';
import '../services/scrip_service.dart';
import '../services/storage_service.dart';
import '../strategies/base_strategy.dart';
import '../strategies/dominance_breakout_strategy.dart';
import '../strategies/strategy_registry.dart';
import '../strategies/strategy_engine_context.dart';

/// Callback to send status updates back to the UI (via background service).
typedef EngineCallback = void Function(String event, Map<String, dynamic> data);

/// The Strategy Engine â€” orchestrates the complete trading workflow:
///   1. Load instruments (Nifty 500)
///   2. Pre-market: fetch historical data, compute metrics
///   3. Progressive candle fetching at scan intervals (9:20-10:00)
///   4. Screen for dominance candles (from 9:35 onwards)
///   5. Monitor LTP via REST polling for breakout detection
///   6. Place paper/live orders on breakout
///   7. Monitor open trades for SL/target exits
///   8. Auto-stop after market close / screening end
///
/// Runs entirely in the background isolate. Uses REST APIs only (no WebSocket
/// in isolate â€” Dhan WebSocket needs single connection, REST is simpler here).
class StrategyEngine {
  final String clientId;
  final String accessToken;
  final StrategyConfigModel config;
  final EngineCallback onUpdate;

  // State
  final ScripService _scripService = ScripService();
  Map<int, CandleStatsModel> _stockMetrics = {};
  final List<StrategySignalModel> _activeSignals = [];
  final List<StrategyTradeModel> _trades = [];
  final Set<int> _alreadySignalled = {};
  int _totalSignalsGenerated = 0;
  Map<int, List<Candle>> _todayCandles = {};
  final Map<int, double> _dayOpenPrices = {};
  int _tradesPlacedToday = 0;
  // Aggregate scan diagnostics across all slots so the end-of-day "WHY ZERO"
  // line can pinpoint the dominant rejection cause without us reading every
  // per-slot SCAN event.
  int _totalScanSlots = 0;
  int _totalStocksEvaluated = 0;
  int _totalCandlesEvaluated = 0;
  final Map<String, int> _aggregateRejects = {};
  bool _running = false;
  bool _stopRequested = false;
  String _startTime = '';
  // Cap raised from 50 â†’ 100: per-slot SCAN diagnostics fill the log faster
  // than the legacy event mix and the history sheet needs room to display
  // them alongside trades/exits.
  static const int _maxKeyEvents = 100;
  final List<String> _keyEvents = [];

  // Per-run structured logger; opened in run(), closed in finally block.
  RunLoggerSession? _runLog;
  String? _runId;
  String? _runDate;

  // Nifty 500 security IDs loaded from scrip master
  List<int> _securityIds = [];

  // API rate limiting â€” uses global RateLimiter.instance

  StrategyEngine({
    required this.clientId,
    required this.accessToken,
    required this.config,
    required this.onUpdate,
  });

  bool get isRunning => _running;

  // Final active-stock count reported by a self-contained strategy (its stats
  // live in the strategy, not in _stockMetrics). Used for the run summary.
  int? _customActiveStocks;
  int get _finalActiveStocks => _customActiveStocks ?? _stockMetrics.length;

  /// Main entry point â€” runs the complete strategy workflow.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    final now = DateTime.now();
    _startTime = '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}';

    String endStatus = 'completed';

    try {
      // Initialize file logger in background isolate
      await AppLogger.init();

      // Open a per-run structured log file under {appDocs}/strategy_logs/.
      // Each run gets its own JSONL so the Log Viewer can show forensic
      // detail for any past run even after app_log.txt rolls.
      _runDate =
          '${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}';
      _runId = RunLogger.makeRunId(_runDate!, config.id);
      _runLog = await RunLogger.startRun(
        runId: _runId!,
        date: _runDate!,
        configId: config.id,
        configName: config.name,
        strategyType: config.strategyType,
        paperTrading: config.paperTrading,
        startTime: _startTime,
      );

      _log('Engine', 'â•â•â• STRATEGY ENGINE STARTING â•â•â•');
      _log('Engine', 'Strategy: ${config.name}');
      _log('Engine', 'Mode: ${config.paperTrading ? "PAPER" : "LIVE"}');
      _log('Engine', 'Config ID: ${config.id}');
      _log('Engine', 'Run log: $_runId');
      _addKeyEvent('Engine started (${config.paperTrading ? "Paper" : "Live"})');

      _sendUpdate('phase', {'phase': 'loading', 'message': 'Loading instruments...'});

      // Step 1: Load scrip master and get Nifty 500 IDs
      await _loadInstruments();
      if (_stopRequested) { endStatus = 'stopped'; return; }

      _addKeyEvent('Loaded ${_securityIds.length} instruments');

      // A self-contained strategy (hasCustomEngine) runs its own full session
      // â€” pre-market, screening, entry and exit â€” through the engine faÃ§ade.
      // Dominance (and any scanâ†’breakout strategy) uses the built-in path.
      final customStrategy = StrategyRegistry.create(config.strategyType);
      if (customStrategy == null) {
        // Registry miss — almost always a per-isolate init bug (the background
        // isolate has its own memory; StrategyRegistry.init() must run here too).
        // Do NOT silently fall through to the hardcoded Dominance inline path:
        // that once ran Dominance live for a Hammer config and masked the bug.
        // Fail loudly instead so the wrong strategy can never run silently.
        _log('Engine',
            'FATAL: strategy type "${config.strategyType}" is not registered in this isolate — aborting (did StrategyRegistry.init() run on start?)');
        _addKeyEvent('ERROR: strategy "${config.strategyType}" not registered — not running');
        endStatus = 'error';
        return;
      }
      if (customStrategy.hasCustomEngine) {
        _sendUpdate('phase',
            {'phase': 'preparing', 'message': 'Preparing strategy...'});
        await customStrategy.runLive(_LiveEngineCtx(this));
        if (_stopRequested) { endStatus = 'stopped'; return; }
      } else {
        // Step 2: Pre-market data loading (historical candles â†’ metrics)
        _sendUpdate('phase',
            {'phase': 'preparing', 'message': 'Loading historical data...'});
        await _loadPreMarketData();
        if (_stopRequested) { endStatus = 'stopped'; return; }

        _log('Engine', 'Pre-market data loaded for ${_stockMetrics.length} stocks');
        _addKeyEvent('Pre-market data loaded for ${_stockMetrics.length} stocks');
        _sendUpdate('phase', {
          'phase': 'prepared',
          'message': '${_stockMetrics.length} stocks ready',
          'stockCount': _stockMetrics.length,
        });

        // Step 3: Wait for market and run progressive screening
        await _runProgressiveScreening();
        if (_stopRequested) { endStatus = 'stopped'; return; }
      }

      // Step 4: Generate summary
      _generateSummary();

      _log('Engine', 'â•â•â• STRATEGY ENGINE COMPLETE â•â•â•');
      _sendUpdate('completed', {
        'message': 'Strategy completed for today',
        'trades': _trades.length,
        'signals': _activeSignals.length,
      });
    } catch (e, stack) {
      endStatus = 'error';
      _log('Engine', 'FATAL ERROR: $e\n$stack');
      _addKeyEvent('ERROR: $e');
      _sendUpdate('error', {'message': 'Engine error: $e'});
    } finally {
      _running = false;
      // Save trades to storage
      await _saveTrades();
      // Save daily run summary for history
      await _saveDailyRunSummary(endStatus);
      // Close per-run log file with final status + summary so the Runs tab
      // can show counts without needing to parse the JSONL.
      final closeNow = DateTime.now();
      final endTime =
          '${closeNow.hour.toString().padLeft(2, "0")}:${closeNow.minute.toString().padLeft(2, "0")}:${closeNow.second.toString().padLeft(2, "0")}';
      final totalPnl = _trades.fold<double>(0, (sum, t) => sum + t.pnl);
      await _runLog?.close(
        status: endStatus,
        endTime: endTime,
        signals: _totalSignalsGenerated,
        trades: _trades.length,
        totalStocks: _securityIds.length,
        finalActiveStocks: _finalActiveStocks,
        totalPnl: totalPnl,
      );
    }
  }

  /// Stop the engine gracefully.
  void stop() {
    _log('Engine', 'Stop requested');
    _stopRequested = true;
    _running = false;
  }

  // â”€â”€ Step 1: Load Instruments â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _loadInstruments() async {
    _log('Engine', 'Step 1: Loading instruments...');

    // Load scrip master (from cache or API)
    await _scripService.loadScrips(clientId: clientId, accessToken: accessToken);
    await _scripService.loadIndexConstituents();
    _log('Engine', 'Scrip master loaded: ${_scripService.isLoaded ? "yes" : "FAILED"}');

    // Get Nifty 500 security IDs
    if (config.securityIds.isNotEmpty) {
      _securityIds = List.from(config.securityIds);
    } else {
      _securityIds = _scripService.getSecurityIdsForUniverse('Nifty 500');
    }

    _log('Engine', 'Stock universe: ${_securityIds.length} stocks');
    _sendUpdate('update', {
      'status': 'running',
      'message': 'Loaded ${_securityIds.length} stocks',
    });
  }

  // â”€â”€ Step 2: Pre-Market Data Loading â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _loadPreMarketData() async {
    final days = (config.params['historicalDays'] as num?)?.toInt() ?? 10;
    _log('Engine', 'Step 2: Loading $days days of historical data for ${_securityIds.length} stocks...');

    int success = 0;
    int failed = 0;
    String? firstFailReason;

    for (int i = 0; i < _securityIds.length; i++) {
      if (_stopRequested) return;

      final secId = _securityIds[i];
      final scrip = _scripService.findById(secId);
      final symbol = scrip?.symbol ?? secId.toString();

      try {
        final metrics = await _loadStockMetrics(secId, symbol, days);
        if (metrics != null) {
          _stockMetrics[secId] = metrics;
          success++;
        } else {
          failed++;
          // Log first 3 failures to help diagnose
          if (failed <= 3) {
            _log('Engine', 'WARN: $symbol ($secId) returned 0 candles for all $days days');
          }
        }
      } catch (e) {
        failed++;
        if (failed <= 3) {
          _log('Engine', 'ERROR: $symbol ($secId) pre-market exception: $e');
        }
        firstFailReason ??= '$symbol: $e';
      }

      // Early diagnostic: if first 10 stocks all failed, log a warning
      if (i == 9 && success == 0 && failed == 10) {
        _log('Engine', 'WARNING: First 10 stocks ALL failed! Possible API/auth issue. First failure: ${firstFailReason ?? "unknown"}');
      }

      // Progress update every 25 stocks
      if ((i + 1) % 25 == 0 || i == _securityIds.length - 1) {
        final pct = ((i + 1) / _securityIds.length * 100).toInt();
        _sendUpdate('update', {
          'status': 'running',
          'message': 'Pre-market: ${i + 1}/${_securityIds.length} stocks ($pct%)',
          'progress': pct,
        });
        _log('Engine', 'Pre-market progress: ${i + 1}/${_securityIds.length} (success=$success, failed=$failed)');
      }
    }

    _log('Engine', 'Pre-market complete: $success success, $failed failed');
    if (failed > 0 && success == 0) {
      // Build actionable error message from what _logOnce captured
      final causes = <String>[];
      if (_loggedOnce.contains('auth_fail')) causes.add('ACCESS TOKEN EXPIRED â€” generate a new token on Dhan developer portal');
      if (_loggedOnce.contains('rate_429') || _loggedOnce.contains('dhan_805') || _loggedOnce.contains('dhan_DH-904')) causes.add('RATE LIMITED â€” too many API calls, try increasing delay');
      if (_loggedOnce.contains('fetch_exception')) causes.add('NETWORK ERROR â€” check internet connection');
      if (causes.isEmpty) causes.add('ALL DATES RETURNED EMPTY â€” possible market holiday week or API issue');

      _log('Engine', 'CRITICAL: ALL $failed stocks failed pre-market data load! 0 candidates will be found.');
      _log('Engine', 'CRITICAL: Root cause: ${causes.join(" | ")}');
      _log('Engine', 'CRITICAL: FIX â†’ ${causes.first.split(" â€” ").last}');
    }

    // Remove security IDs that have no metrics
    _securityIds = _securityIds.where((id) => _stockMetrics.containsKey(id)).toList();

    // â”€â”€ PREMARKET QUALITY summary â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // If a chunk of stocks have garbage averages (avgVol == 0 or tiny), the
    // dominance rules will silently reject every one. Surfacing this in
    // both the activity log and the run JSONL makes that case obvious.
    if (_stockMetrics.isNotEmpty) {
      final vols = _stockMetrics.values.map((m) => m.avgVolume).toList()
        ..sort();
      final minVol = vols.first;
      final maxVol = vols.last;
      final p50 = vols[vols.length ~/ 2];
      final badZero = vols.where((v) => v == 0).length;
      final badLow = vols.where((v) => v > 0 && v < 1000).length;

      final summary =
          'PREMARKET: ${_stockMetrics.length} loaded | avgVol p50=${_fmtVol(p50)} min=${_fmtVol(minVol)} max=${_fmtVol(maxVol)} | bad(avgVol<1k)=$badLow | bad(=0)=$badZero';
      _log('Engine', summary);
      _addKeyEvent(summary);
      _runLog?.info('PreMarket', 'Pre-market data quality', {
        'loaded': _stockMetrics.length,
        'avgVol_p50': p50,
        'avgVol_min': minVol,
        'avgVol_max': maxVol,
        'badLowVol': badLow,
        'badZeroVol': badZero,
      });

      // Per-stock prevClose snapshot â€” written to JSONL only (no activity-log
      // noise). Lets devs `grep <SYMBOL>` in the run log to see the exact
      // prevClose live used, then diff against backtest's snapshot to confirm
      // whether a stock's R8-Gap reject was driven by a data-source mismatch
      // (corporate action, adjusted vs unadjusted close, stale cache).
      final prevCloseBySymbol = <String, double>{};
      for (final m in _stockMetrics.values) {
        prevCloseBySymbol[m.symbol] = m.prevClose;
      }
      _runLog?.info(
        'PreMarket',
        'Per-stock prevClose snapshot (${prevCloseBySymbol.length} stocks)',
        {'prevCloseBySymbol': prevCloseBySymbol},
      );
    }
  }

  String _fmtVol(double v) {
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}k';
    return v.toStringAsFixed(0);
  }

  Future<CandleStatsModel?> _loadStockMetrics(int secId, String symbol, int days) async {
    final allCandles = <Candle>[];
    final today = DateTime.now();

    // The loop iterates daysBack = 1, 2, 3, ... so the FIRST successful fetch
    // is for the most recent prior trading day â€” which is what R8-Gap needs
    // for stats.prevClose. Capture its newest candle here.
    //
    // Earlier this took `allCandles.last.close`, which, because allCandles is
    // built by appending each day's bars oldest-first in reverse-chronological
    // iteration order, ended up being the OLDEST fetched day's last bar
    // (i.e. ~14 calendar days ago). That blew the R8-Gap math for every stock
    // â€” sometimes silently, sometimes loudly (MCX 2026-05-19 lost the trade
    // to a fake -13% gap because prevClose was its 2026-05-05 close, not
    // 2026-05-18's). Verified against Dhan's live API via
    // dhan-api-probes/Probe-PrevCloseMismatch.ps1.
    double? mostRecentClose;

    int fetched = 0;
    int daysBack = 0;
    int emptyDays = 0;
    int errorDays = 0;
    while (fetched < days && daysBack < days + 15) {
      daysBack++;
      final date = today.subtract(Duration(days: daysBack));
      if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) continue;

      try {
        final candles = await _fetchIntradayCandles(secId, '5', date: date);
        if (candles.isNotEmpty) {
          // candles is newest-first per _parseCandles, so candles.first is
          // the day's last 5-min bar. ??= ensures only the first successful
          // (= most-recent) day's value wins.
          mostRecentClose ??= candles.first.close;
          allCandles.addAll(candles.reversed); // oldest first within the day
          fetched++;
        } else {
          emptyDays++;
        }
      } catch (e) {
        errorDays++;
      }
    }

    if (allCandles.isEmpty) {
      // Only log first stock's breakdown to avoid spam â€” _logOnce ensures one entry
      _logOnce('Engine',
          'DEBUG: First stock failure breakdown â€” $symbol: emptyDays=$emptyDays, errorDays=$errorDays, daysChecked=$daysBack '
          '(empty=API returned no candles for that date, error=network/API exception)',
          'first_stock_fail');
      return null;
    }

    final avgVolume = allCandles.fold<double>(0, (sum, c) => sum + c.volume) / allCandles.length;
    final avgCandleSize = allCandles.fold<double>(0, (sum, c) => sum + (c.high - c.low)) / allCandles.length;
    final prevClose = mostRecentClose ?? 0.0;

    return CandleStatsModel(
      securityId: secId,
      symbol: symbol,
      avgCandleSize: avgCandleSize,
      avgVolume: avgVolume,
      prevClose: prevClose,
      totalCandles: allCandles.length,
    );
  }

  // â”€â”€ Step 3: Progressive Candle Fetching & Screening â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _runProgressiveScreening() async {
    _log('Engine', 'Step 3: Starting progressive screening...');

    final params = config.params;
    final scanStartHour = (params['scanStartHour'] as num?)?.toInt() ?? 9;
    final scanStartMin = (params['scanStartMin'] as num?)?.toInt() ?? 30;
    final scanEndHour = (params['scanEndHour'] as num?)?.toInt() ?? 10;
    final scanEndMin = (params['scanEndMin'] as num?)?.toInt() ?? 0;
    final scanInterval = (params['scanIntervalMinutes'] as num?)?.toInt() ?? 5;
    final minAbsoluteVolume = (params['minAbsoluteVolume'] as num?)?.toInt() ?? 5000;

    // Build screening times: first fetch at 9:20, then every 5 min until scan end
    // C# fetches at: 9:20, 9:25, 9:30, 9:35, 9:40, 9:45, 9:50, 9:55, 10:00
    final today = DateTime.now();
    final screeningTimes = <DateTime>[];

    // Start fetching from 9:20 (first candle at 9:15 + 5 min)
    var fetchTime = DateTime(today.year, today.month, today.day, 9, 20);
    final screeningEnd = DateTime(today.year, today.month, today.day, scanEndHour, scanEndMin);

    while (!fetchTime.isAfter(screeningEnd)) {
      screeningTimes.add(fetchTime);
      fetchTime = fetchTime.add(Duration(minutes: scanInterval));
    }

    _log('Engine', 'Screening times: ${screeningTimes.map((t) => '${t.hour}:${t.minute.toString().padLeft(2, "0")}').join(", ")}');

    // Active instruments (progressively reduced by volume)
    var activeIds = List<int>.from(_securityIds);

    final scanStartTime = Duration(hours: scanStartHour, minutes: scanStartMin);

    for (final screenTime in screeningTimes) {
      if (_stopRequested) return;

      // Wait until screening time (with 5 sec buffer for candle close)
      final targetTime = screenTime.add(const Duration(seconds: 5));
      final now = DateTime.now();
      if (targetTime.isAfter(now)) {
        final waitDuration = targetTime.difference(now);
        _log('Engine', 'Waiting ${waitDuration.inSeconds}s until ${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")}...');
        _sendUpdate('update', {
          'status': 'running',
          'message': 'Waiting for ${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")} candle...',
        });

        // Wait in small chunks so we can check for stop
        final waitEnd = now.add(waitDuration);
        while (DateTime.now().isBefore(waitEnd)) {
          if (_stopRequested) return;
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (_stopRequested) return;

      // Fetch candles for active stocks (always from 9:15 to current time)
      _log('Engine', 'Fetching candles for ${activeIds.length} stocks at ${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")}...');
      _sendUpdate('update', {
        'status': 'running',
        'message': 'Fetching ${activeIds.length} stocks (${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")})...',
      });

      int elimNoData = 0;
      int elimLowVol = 0;
      int elimApiErr = 0;
      int strippedIncomplete = 0; // stocks where we dropped the live in-progress bar
      final toRemove = <int>[];
      // Track the most-recent candle time across all stocks fetched this slot.
      // If "latest" lags behind the expected just-closed candle by more than
      // one bar, Dhan's backend hasn't finalised the bar yet â€” the dominance
      // rules will likely reject it on partial volume.
      int? latestCandleMinute;
      final staleHistogram = <int, int>{}; // minutes-of-day â†’ count

      // Slot minute used to strip Dhan's currently-forming bar. When we fetch
      // at e.g. 09:20:05 Dhan returns the just-opened 09:20â€“09:25 bar with
      // only seconds of trade data; treating that as a closed candle made the
      // volume filter and dominance rules see flat near-zero bars and falsely
      // reject ~60% of the universe. Backtest never hit this because cached
      // candles are always closed bars.
      final slotMinuteOfDay = screenTime.hour * 60 + screenTime.minute;

      for (final secId in activeIds) {
        if (_stopRequested) return;

        try {
          final candles = await _fetchIntradayCandles(secId, '5', date: today);
          if (candles.isEmpty) {
            toRemove.add(secId);
            elimNoData++;
            continue;
          }

          // Drop the still-forming bar (start time >= this slot).
          final closedNewestFirst = candles
              .where((c) =>
                  c.date.hour * 60 + c.date.minute < slotMinuteOfDay)
              .toList();
          if (closedNewestFirst.length != candles.length) {
            strippedIncomplete++;
          }
          if (closedNewestFirst.isEmpty) {
            toRemove.add(secId);
            elimNoData++;
            continue;
          }

          // Store candles (oldest first)
          _todayCandles[secId] = closedNewestFirst.reversed.toList();

          // Store day open price
          if (!_dayOpenPrices.containsKey(secId) && _todayCandles[secId]!.isNotEmpty) {
            _dayOpenPrices[secId] = _todayCandles[secId]!.first.open;
          }

          // Volume filter: latest candle must have >= minAbsoluteVolume
          final latestCandle = _todayCandles[secId]!.last;
          final latestMin =
              latestCandle.date.hour * 60 + latestCandle.date.minute;
          staleHistogram[latestMin] = (staleHistogram[latestMin] ?? 0) + 1;
          if (latestCandleMinute == null || latestMin > latestCandleMinute) {
            latestCandleMinute = latestMin;
          }
          if (latestCandle.volume < minAbsoluteVolume) {
            toRemove.add(secId);
            elimLowVol++;
          }
        } catch (e) {
          toRemove.add(secId);
          elimApiErr++;
        }
      }

      // â”€â”€ FETCH freshness diagnostic (file log only â€” too noisy for activity)
      if (latestCandleMinute != null) {
        // Expected: the candle that just closed = screenTime - scanInterval.
        // At slot 9:35, expected latest = 9:30 candle (start time 9:30).
        final expectedMin = screenTime.hour * 60 +
            screenTime.minute -
            scanInterval;
        final stale = staleHistogram.entries
            .where((e) => e.key < expectedMin)
            .fold<int>(0, (sum, e) => sum + e.value);
        final clean = staleHistogram[latestCandleMinute] ?? 0;
        final freshness =
            'FETCH [${screenTime.hour.toString().padLeft(2, "0")}:${screenTime.minute.toString().padLeft(2, "0")}] '
            'latest=${(latestCandleMinute ~/ 60).toString().padLeft(2, "0")}:${(latestCandleMinute % 60).toString().padLeft(2, "0")} '
            'expected=${(expectedMin ~/ 60).toString().padLeft(2, "0")}:${(expectedMin % 60).toString().padLeft(2, "0")} '
            'clean=$clean stale=$stale incomplete=$strippedIncomplete';
        _log('Engine', freshness);
        _runLog?.info('Fetch', freshness, {
          'slot': '${screenTime.hour.toString().padLeft(2, "0")}:${screenTime.minute.toString().padLeft(2, "0")}',
          'latestCandleMin': latestCandleMinute,
          'expectedMin': expectedMin,
          'cleanStocks': clean,
          'staleStocks': stale,
          'strippedIncompleteBars': strippedIncomplete,
        });
      }

      // Remove eliminated stocks and log summary
      final totalElim = elimNoData + elimLowVol + elimApiErr;
      if (toRemove.isNotEmpty) {
        activeIds.removeWhere((id) => toRemove.contains(id));
        _log('Engine',
          'Eliminated $totalElim stocks at ${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")} '
          'â€” LowVolume: $elimLowVol, NoData: $elimNoData, ApiError: $elimApiErr. '
          'Remaining: ${activeIds.length}');
        _addKeyEvent('Eliminated $totalElim (Vol:$elimLowVol NoData:$elimNoData Err:$elimApiErr) â†’ ${activeIds.length} remaining');
      }

      // Screen for dominance candles (only from scanStartTime onwards, C#: 9:35)
      final screenTimeOfDay = Duration(hours: screenTime.hour, minutes: screenTime.minute);
      final slotLabel =
          '${screenTime.hour.toString().padLeft(2, "0")}:${screenTime.minute.toString().padLeft(2, "0")}';
      if (screenTimeOfDay >= scanStartTime) {
        _log('Engine', 'Screening for dominance candles...');
        _screenForDominance(slotLabel: slotLabel);

        _sendUpdate('update', {
          'status': 'running',
          'message': '${_activeSignals.length} candidates found, ${activeIds.length} stocks active',
          'candidates': _activeSignals.length,
          'activeStocks': activeIds.length,
        });
      } else {
        _log('Engine', 'Candles fetched (screening starts at $scanStartHour:${scanStartMin.toString().padLeft(2, "0")})');
      }

      // After scanning, monitor LTP for breakout on active signals
      if (_activeSignals.isNotEmpty) {
        await _monitorBreakouts();
      }
    }

    _log('Engine', 'Progressive screening complete. Final active stocks: ${activeIds.length}');
    _log('Engine', 'Total dominance candidates: ${_alreadySignalled.length}');
    _log('Engine', 'Total trades: ${_trades.length}');

    // Continue monitoring existing positions until market close or all positions closed
    if (_trades.any((t) => t.status == TradeStatus.open)) {
      _log('Engine', 'Monitoring open positions until market close...');
      await _monitorOpenPositions();
    }
  }

  // â”€â”€ Dominance Candle Screening â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _screenForDominance({String? slotLabel}) {
    final strategy = DominanceBreakoutStrategy();
    ScanReport? lastReport;

    final signals = strategy.scan(
      configId: config.id,
      stats: _stockMetrics,
      todayCandles: _todayCandles,
      params: config.params,
      scripService: _scripService,
      alreadySignalled: _alreadySignalled,
      // Plain-text summary line ("REJECTION SUMMARY: ...") still mirrors to
      // the activity log; per-stock detail goes through onStockReject.
      debugLog: (msg) => _log('Scan', msg),
      onScanReport: (report) => lastReport = report,
      onStockReject: (ev) => _runLog?.info(
        'Reject',
        '${ev.symbol} ${ev.rule} @${ev.candleTime.hour.toString().padLeft(2, "0")}:${ev.candleTime.minute.toString().padLeft(2, "0")}: ${ev.detail}',
        ev.toJson(),
      ),
    );

    // â”€â”€ Per-slot structured SCAN summary â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // The single most useful line for "why did this day produce 0 signals":
    // it shows how many stocks even reached the rules and which rule killed
    // them. Goes to both the activity log (compact summary in history view)
    // and the run JSONL (full structured payload).
    if (lastReport != null) {
      final r = lastReport!;
      _totalScanSlots++;
      _totalStocksEvaluated += r.stocksEvaluated;
      _totalCandlesEvaluated += r.candlesInWindow;
      r.rejectCounts.forEach((rule, count) {
        _aggregateRejects[rule] = (_aggregateRejects[rule] ?? 0) + count;
      });
      final topRej = r.topRejects(3).join(' ');
      final tagLabel = slotLabel ?? 'now';
      final compact =
          'SCAN [$tagLabel] in=${r.stocksEvaluated} window=${r.candlesInWindow} signals=${signals.length}'
          '${topRej.isEmpty ? "" : " | $topRej"}';
      _log('Engine', compact);
      _addKeyEvent(compact);
      _runLog?.info('Scan', compact, {
        'slot': slotLabel,
        'stocksEvaluated': r.stocksEvaluated,
        'candlesInWindow': r.candlesInWindow,
        'signals': signals.length,
        'rejectCounts': r.rejectCounts,
        'totalRejects': r.totalRejects,
      });
    }

    final maxTrades = (config.params['maxTradesPerDay'] as num?)?.toInt() ?? 2;

    for (final signal in signals) {
      _alreadySignalled.add(signal.securityId);
      _totalSignalsGenerated++;
      final sigTime = '${signal.timestamp.hour.toString().padLeft(2, '0')}:${signal.timestamp.minute.toString().padLeft(2, '0')}';
      final expTime = '${signal.expiryTime.hour.toString().padLeft(2, '0')}:${signal.expiryTime.minute.toString().padLeft(2, '0')}';
      _log('Engine', 'DOMINANCE FOUND: ${signal.symbol} Break=${signal.entryPrice} SL=${signal.stopLoss} Window=$sigTimeâ†’$expTime');
      _addKeyEvent('DOMINANCE: ${signal.symbol} Break=${signal.entryPrice}');

      _sendUpdate('signal_found', {
        'symbol': signal.symbol,
        'securityId': signal.securityId,
        'entryPrice': signal.entryPrice,
        'stopLoss': signal.stopLoss,
        'reason': signal.reason,
      });

      // Immediate breakout check: candle data we already fetched may show that
      // the high exceeded dominance high during the screening delay.
      // Without this, a breakout during the ~1 min screening loop is missed.
      bool immediateBreakout = false;
      if (_tradesPlacedToday < maxTrades) {
        final candles = _todayCandles[signal.securityId];
        if (candles != null && candles.isNotEmpty) {
          final latestCandle = candles.last;
          if (latestCandle.high > signal.entryPrice) {
            _log('Engine', 'IMMEDIATE BREAKOUT: ${signal.symbol} candle high=${latestCandle.high} > Entry=${signal.entryPrice} (caught during screening)');
            final trade = _calculateTrade(signal, latestCandle.high);
            if (trade != null) {
              _trades.add(trade);
              _tradesPlacedToday++;
              immediateBreakout = true;

              _log('Engine', 'TRADE: ${trade.symbol} Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss} Target=${trade.target}');
              _addKeyEvent('TRADE: ${trade.symbol} Qty=${trade.quantity} @ ${trade.entryPrice} (immediate)');

              _sendUpdate('trade_update', {
                'type': 'entry',
                'symbol': trade.symbol,
                'securityId': trade.securityId,
                'entryPrice': trade.entryPrice,
                'quantity': trade.quantity,
                'stopLoss': trade.stopLoss,
                'target': trade.target,
                'isPaper': trade.isPaperTrade,
              });

              if (!config.paperTrading) {
                _placeLiveOrder(trade);
              }
            }
          }
        }
      }

      // Only add to active monitoring if no immediate breakout
      if (!immediateBreakout) {
        _activeSignals.add(signal);
      }
    }

    if (signals.isNotEmpty) {
      _log('Engine', 'New dominance candidates: ${signals.length}. Total active: ${_activeSignals.length}');
    }
  }

  // â”€â”€ Breakout Monitoring (REST LTP polling) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _monitorBreakouts() async {
    if (_activeSignals.isEmpty) return;
    if (_stopRequested) return;

    final maxTrades = (config.params['maxTradesPerDay'] as num?)?.toInt() ?? 2;
    if (_tradesPlacedToday >= maxTrades) {
      _log('Engine', 'Max trades ($maxTrades) reached â€” skipping breakout monitor');
      return;
    }

    final startCount = _activeSignals.length;
    final shortestExpiry = _activeSignals
        .map((s) => s.expiryTime)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    _log('Engine',
        'Monitoring LTP for $startCount candidates until ${shortestExpiry.hour.toString().padLeft(2, "0")}:${shortestExpiry.minute.toString().padLeft(2, "0")} (loop @ ~1 Hz)...');

    int polls = 0;
    int breakoutsHit = 0;
    int expiries = 0;
    int partialBarHits = 0;

    // â”€â”€ Phase 0: catch breakouts that happened DURING the slot fetch delay.
    //
    // The slot fetch can take ~3 min when rate-limited at 5 req/sec across
    // 350+ stocks. By the time we enter this monitor, the bar *after* the
    // dominance candle has been forming for those 3 minutes. Its rolling
    // "high" already reflects any tick that touched entry â€” the per-second
    // LTP loop below would miss this because LTP is a point-in-time snapshot.
    //
    // Re-fetch each signal's intraday data and inspect bars AFTER the
    // dominance candle. If any of them already broke above entry, enter
    // immediately at the dominance price (the breakout happened â€” we just
    // weren't watching). Restricting to post-dominance bars avoids a
    // false-trigger from an earlier intraday spike whose high was unrelated
    // to the dominance pattern.
    for (final signal in List.of(_activeSignals)) {
      if (_stopRequested) break;
      if (_tradesPlacedToday >= maxTrades) break;
      try {
        final candles =
            await _fetchIntradayCandles(signal.securityId, '5', date: DateTime.now());
        if (candles.isEmpty) continue;

        // candles are newest-first per _parseCandles. Find the dominance
        // candle by OHLC fingerprint â€” its index splits the list into
        // post-dominance (newer, indices < dominanceIdx) and pre-dominance
        // (older, > dominanceIdx).
        int dominanceIdx = -1;
        for (int i = 0; i < candles.length; i++) {
          final c = candles[i];
          if ((c.open - signal.candleOpen).abs() < 0.01 &&
              (c.high - signal.candleHigh).abs() < 0.01 &&
              (c.low - signal.candleLow).abs() < 0.01 &&
              (c.close - signal.candleClose).abs() < 0.01) {
            dominanceIdx = i;
            break;
          }
        }
        if (dominanceIdx <= 0) {
          // -1 = couldn't find (unexpected); 0 = dominance is the newest bar
          // (no post-dominance bars exist yet). Either way, fall through to
          // the LTP poll loop.
          continue;
        }

        // Post-dominance bars are at indices [0, dominanceIdx). In
        // newest-first order, dominanceIdx-1 is the oldest of those; loop
        // from there toward 0 to find the EARLIEST bar that breached entry.
        Candle? breakBar;
        for (int i = dominanceIdx - 1; i >= 0; i--) {
          if (candles[i].high > signal.entryPrice) {
            breakBar = candles[i];
            break;
          }
        }

        if (breakBar != null) {
          final barLabel =
              '${breakBar.date.hour.toString().padLeft(2, "0")}:${breakBar.date.minute.toString().padLeft(2, "0")}';
          _log('Engine',
              'BREAKOUT (partial-bar): ${signal.symbol} bar=$barLabel high=${breakBar.high} > Entry=${signal.entryPrice} â€” caught during fetch-delay window');

          final trade = _calculateTrade(signal, breakBar.high);
          if (trade != null) {
            _trades.add(trade);
            _tradesPlacedToday++;
            _activeSignals.remove(signal);
            partialBarHits++;

            _log('Engine',
                'TRADE: ${trade.symbol} Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss} Target=${trade.target}');
            _addKeyEvent(
                'TRADE: ${trade.symbol} Qty=${trade.quantity} @ ${trade.entryPrice}');
            _sendUpdate('trade_update', {
              'type': 'entry',
              'symbol': trade.symbol,
              'securityId': trade.securityId,
              'entryPrice': trade.entryPrice,
              'quantity': trade.quantity,
              'stopLoss': trade.stopLoss,
              'target': trade.target,
              'isPaper': trade.isPaperTrade,
            });
            if (!config.paperTrading) {
              await _placeLiveOrder(trade);
            }
          }
        }
      } catch (e) {
        _log('Engine',
            'Partial-bar pre-check error for ${signal.symbol}: $e');
      }
    }

    if (_activeSignals.isEmpty || _tradesPlacedToday >= maxTrades) {
      _log('Engine',
          'Breakout monitor done (partial-bar phase): candidates=$startCount entered=$partialBarHits â€” skipping LTP poll loop');
      return;
    }

    // Loop until every signal has either entered, expired, or we hit maxTrades.
    // Previously this was a single LTP snapshot per slot â€” if the breakout
    // happened in between two slot ticks (which is most of the breakout
    // window, since slots are 5 min apart), live missed it while the backtest
    // saw the bar's full high and entered. Now we poll continuously; the
    // RateLimiter on ApiCategory.quote (1 req/sec) throttles the loop.
    while (!_stopRequested &&
        _activeSignals.isNotEmpty &&
        _tradesPlacedToday < maxTrades) {
      final signalSecIds = _activeSignals.map((s) => s.securityId).toList();

      try {
        final ltpMap = await _fetchLtpBatch(signalSecIds);
        polls++;

        for (final signal in List.of(_activeSignals)) {
          final ltp = ltpMap[signal.securityId];
          if (ltp == null || ltp <= 0) continue;

          if (ltp > signal.entryPrice) {
            _log('Engine',
                'BREAKOUT: ${signal.symbol} LTP=$ltp > Entry=${signal.entryPrice}');

            final trade = _calculateTrade(signal, ltp);
            if (trade != null) {
              _trades.add(trade);
              _tradesPlacedToday++;
              _activeSignals.remove(signal);
              breakoutsHit++;

              _log('Engine',
                  'TRADE: ${trade.symbol} Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss} Target=${trade.target}');
              _addKeyEvent(
                  'TRADE: ${trade.symbol} Qty=${trade.quantity} @ ${trade.entryPrice}');

              _sendUpdate('trade_update', {
                'type': 'entry',
                'symbol': trade.symbol,
                'securityId': trade.securityId,
                'entryPrice': trade.entryPrice,
                'quantity': trade.quantity,
                'stopLoss': trade.stopLoss,
                'target': trade.target,
                'isPaper': trade.isPaperTrade,
              });

              if (!config.paperTrading) {
                await _placeLiveOrder(trade);
              }
              continue; // signal already removed
            }
          }

          if (DateTime.now().isAfter(signal.expiryTime)) {
            _log('Engine',
                'EXPIRED: ${signal.symbol} â€” no breakout before ${signal.expiryTime}, can be re-screened (polls=$polls)');
            _activeSignals.remove(signal);
            _alreadySignalled.remove(signal.securityId);
            expiries++;
          }
        }
      } catch (e) {
        _log('Engine', 'LTP fetch error: $e');
        // Brief backoff on fetch error so we don't tight-loop on persistent failure.
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _log('Engine',
        'Breakout monitor done: candidates=$startCount entered=${partialBarHits + breakoutsHit} (partial-bar=$partialBarHits ltp-poll=$breakoutsHit) expired=$expiries polls=$polls');
  }

  StrategyTradeModel? _calculateTrade(StrategySignalModel signal, double ltp) {
    final fixedSL = (config.params['fixedStopLoss'] as num?)?.toDouble() ?? 500;
    final fixedTarget = (config.params['fixedTarget'] as num?)?.toDouble() ?? 2000;

    final entryPrice = signal.entryPrice;
    final slPrice = signal.stopLoss;
    final riskPerShare = entryPrice - slPrice;

    if (riskPerShare <= 0) return null;

    final quantity = (fixedSL / riskPerShare).floor();
    if (quantity <= 0) return null;

    final targetPrice = entryPrice + (fixedTarget / quantity);

    return StrategyTradeModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      strategyConfigId: config.id,
      signalId: signal.id,
      securityId: signal.securityId,
      symbol: signal.symbol,
      status: TradeStatus.open,
      isPaperTrade: config.paperTrading,
      entryPrice: entryPrice,
      quantity: quantity,
      entryTime: DateTime.now(),
      stopLoss: slPrice,
      target: targetPrice,
    );
  }

  // â”€â”€ Monitor Open Positions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _monitorOpenPositions() async {
    // Square off at 15:30 IST â€” same point in time as the backtest, which
    // exits at the close of the last 5-min candle (15:25-15:30 bar). This
    // used to be 15:15, which left a 15-minute window where backtest already
    // had a final EOD price but live was still polling, so an end-of-day
    // ACMESOLAR-style position got squared off with no real exit price
    // (exitPrice was wrongly set to entryPrice, hiding the P&L).
    final marketClose = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      15, 30,
    );

    while (!_stopRequested && DateTime.now().isBefore(marketClose)) {
      final openTrades = _trades.where((t) => t.status == TradeStatus.open).toList();
      if (openTrades.isEmpty) break;

      try {
        final secIds = openTrades.map((t) => t.securityId).toList();
        final ltpMap = await _fetchLtpBatch(secIds);

        for (final trade in openTrades) {
          final ltp = ltpMap[trade.securityId];
          if (ltp == null || ltp <= 0) continue;

          // Check SL
          if (ltp <= trade.stopLoss) {
            trade.status = TradeStatus.closed;
            trade.exitPrice = trade.stopLoss;
            trade.exitTime = DateTime.now();
            trade.outcome = TradeOutcome.stopLoss;
            _log('Engine',
                'SL HIT: ${trade.symbol} @ ${trade.stopLoss} P&L=â‚¹${trade.pnl.toStringAsFixed(0)}');
            _sendTradeUpdate(trade, 'sl_hit');
          }
          // Check target
          else if (ltp >= trade.target) {
            trade.status = TradeStatus.closed;
            trade.exitPrice = trade.target;
            trade.exitTime = DateTime.now();
            trade.outcome = TradeOutcome.target;
            _log('Engine',
                'TARGET HIT: ${trade.symbol} @ ${trade.target} P&L=â‚¹${trade.pnl.toStringAsFixed(0)}');
            _sendTradeUpdate(trade, 'target_hit');
          }
        }
      } catch (e) {
        _log('Engine', 'Position monitor error: $e');
      }

      // Poll every 3 seconds
      await Future.delayed(const Duration(seconds: 3));
    }

    // Square off remaining positions at market close using the latest LTP
    // as exit price, matching the backtest's "exit at last candle's close"
    // semantics. Previously this set exitPrice = entryPrice (P&L = 0),
    // silently dropping the actual EOD return for non-SL/Target exits.
    final remaining = _trades.where((t) => t.status == TradeStatus.open).toList();
    if (remaining.isNotEmpty && !_stopRequested) {
      _log('Engine',
          'Market closing â€” squaring off ${remaining.length} position(s)');
      Map<int, double> ltpMap = const {};
      try {
        ltpMap = await _fetchLtpBatch(
            remaining.map((t) => t.securityId).toList());
      } catch (e) {
        _log('Engine',
            'EOD LTP fetch failed: $e â€” falling back to entry price (P&L will be 0)');
      }
      for (final trade in remaining) {
        final ltp = ltpMap[trade.securityId];
        final exitPx = (ltp != null && ltp > 0) ? ltp : trade.entryPrice;
        trade.status = TradeStatus.closed;
        trade.exitPrice = exitPx;
        trade.exitTime = DateTime.now();
        trade.outcome = TradeOutcome.endOfDay;
        _log('Engine',
            'EOD EXIT: ${trade.symbol} @ ${exitPx.toStringAsFixed(2)} P&L=â‚¹${trade.pnl.toStringAsFixed(0)}');
        _addKeyEvent(
            'EOD EXIT: ${trade.symbol} @ ${exitPx.toStringAsFixed(2)} P&L=â‚¹${trade.pnl.toStringAsFixed(0)}');
        _sendTradeUpdate(trade, 'eod_exit');
      }
    }
  }

  void _sendTradeUpdate(StrategyTradeModel trade, String type) {
    _sendUpdate('trade_update', {
      'type': type,
      'symbol': trade.symbol,
      'securityId': trade.securityId,
      'entryPrice': trade.entryPrice,
      'exitPrice': trade.exitPrice,
      'quantity': trade.quantity,
      'pnl': trade.pnl,
      'outcome': trade.outcome.name,
      'isPaper': trade.isPaperTrade,
    });
  }

  // â”€â”€ Live Order Placement â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _placeLiveOrder(StrategyTradeModel trade) async {
    try {
      _log('Engine', 'Placing LIVE bracket order for ${trade.symbol}...');

      final profitValue = (trade.target - trade.entryPrice).abs();
      final stopLossValue = (trade.entryPrice - trade.stopLoss).abs();

      final body = jsonEncode({
        'dhanClientId': clientId,
        'correlationId': trade.id,
        'transactionType': 'BUY',
        'exchangeSegment': 'NSE_EQ',
        'productType': 'BO',
        'orderType': 'MARKET',
        'validity': 'DAY',
        'securityId': trade.securityId.toString(),
        'quantity': trade.quantity,
        'disclosedQuantity': '',
        'price': '',
        'triggerPrice': '',
        'afterMarketOrder': false,
        'amoTime': '',
        'boProfitValue': profitValue.toStringAsFixed(2),
        'boStopLossValue': stopLossValue.toStringAsFixed(2),
      });

      final response = await http.post(
        Uri.parse('https://api.dhan.co/v2/orders'),
        headers: {
          'access-token': accessToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: body,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        trade.dhanOrderId = json['orderId'] as String?;
        _log('Engine', 'LIVE ORDER PLACED: ${trade.symbol} OrderId=${trade.dhanOrderId}');
      } else {
        _log('Engine', 'LIVE ORDER FAILED: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Engine', 'LIVE ORDER ERROR: $e');
    }
  }

  // â”€â”€ Summary â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _generateSummary() {
    final totalTrades = _trades.length;
    final winners = _trades.where((t) => t.pnl > 0).length;
    final losers = _trades.where((t) => t.pnl < 0).length;
    final totalPnl = _trades.fold<double>(0, (sum, t) => sum + t.pnl);

    _log('Engine', 'â•â•â• END OF DAY SUMMARY â•â•â•');
    _log('Engine', 'Dominance Candidates: ${_alreadySignalled.length}');
    _log('Engine', 'Total Trades: $totalTrades');
    _log('Engine', 'Winners: $winners | Losers: $losers');
    _log('Engine', 'Total P&L: Rs ${totalPnl.toStringAsFixed(2)}');
    _log('Engine', 'â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');

    // â”€â”€ WHY ZERO diagnostic â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Emit a "why nothing fired" line in the activity log when a run ends
    // with zero dominance candidates. This is the line a developer wants
    // to see in history weeks later when troubleshooting a flat day.
    if (_totalSignalsGenerated == 0 && _totalScanSlots > 0) {
      final sortedRej = _aggregateRejects.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final totalRej =
          _aggregateRejects.values.fold<int>(0, (sum, v) => sum + v);

      String diagnosis;
      if (_totalCandlesEvaluated == 0) {
        diagnosis =
            'No candles ever reached the scan window. Likely cause: scan window misconfigured OR Dhan API returned no fresh candles before each slot fired.';
      } else if (sortedRej.isEmpty) {
        diagnosis = 'Scan window had candles but no rejects recorded â€” internal logic gap, please review.';
      } else {
        final top = sortedRej.first;
        final pct = totalRej > 0 ? (top.value * 100 / totalRej).round() : 0;
        // Delegate the human-readable hint to the strategy itself so each
        // strategy ships its own rule-key vocabulary.
        final hint = DominanceBreakoutStrategy().diagnosisHint(top.key) ??
            'See per-stock REJECT lines in run log for detail.';
        diagnosis =
            'Dominant reject: ${top.key} (${top.value}Ã—, $pct%). $hint';
      }

      final summary =
          'WHY ZERO: $_totalScanSlots scan slots Ã— ${(_totalStocksEvaluated / _totalScanSlots).round()} stocks avg = $_totalCandlesEvaluated candle-checks. $diagnosis';
      _log('Engine', summary);
      _addKeyEvent(summary);
      _runLog?.warn('Diagnosis', summary, {
        'scanSlots': _totalScanSlots,
        'avgStocksPerSlot': _totalScanSlots > 0
            ? (_totalStocksEvaluated / _totalScanSlots).round()
            : 0,
        'candlesEvaluated': _totalCandlesEvaluated,
        'aggregateRejects': _aggregateRejects,
      });
    }
  }


  // â”€â”€ Save trades to SharedPreferences â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _saveTrades() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString('strategy_trades');
      final existingTrades = <StrategyTradeModel>[];

      if (existing != null) {
        try {
          final list = jsonDecode(existing) as List<dynamic>;
          existingTrades.addAll(
            list.map((e) => StrategyTradeModel.fromJson(e as Map<String, dynamic>)),
          );
        } catch (_) {}
      }

      existingTrades.addAll(_trades);
      final json = jsonEncode(existingTrades.map((t) => t.toJson()).toList());
      await prefs.setString('strategy_trades', json);
      _log('Engine', 'Saved ${_trades.length} trades to storage');
    } catch (e) {
      _log('Engine', 'Failed to save trades: $e');
    }
  }

  // â”€â”€ Key Events (for daily history) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _addKeyEvent(String event) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}';
    _keyEvents.add('[$ts] $event');
    if (_keyEvents.length > _maxKeyEvents) _keyEvents.removeAt(0);
  }

  // â”€â”€ Save Daily Run Summary â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _saveDailyRunSummary(String status) async {
    try {
      final now = DateTime.now();
      final endTime = '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}';
      final date = '${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}';

      final winners = _trades.where((t) => t.pnl > 0).length;
      final losers = _trades.where((t) => t.pnl < 0).length;
      final totalPnl = _trades.fold<double>(0, (sum, t) => sum + t.pnl);

      final summary = DailyRunSummaryModel(
        date: date,
        configId: config.id,
        configName: config.name,
        strategyType: config.strategyType,
        paperTrading: config.paperTrading,
        totalStocks: _securityIds.length,
        finalActiveStocks: _finalActiveStocks,
        dominanceCandidates: _totalSignalsGenerated,
        totalTrades: _trades.length,
        winners: winners,
        losers: losers,
        totalPnl: totalPnl,
        startTime: _startTime,
        endTime: endTime,
        status: status,
        activityLog: List.from(_keyEvents),
      );

      await StorageService.saveDailyRunSummary(summary);
      _log('Engine', 'Daily run summary saved for $date');
    } catch (e) {
      _log('Engine', 'Failed to save daily summary: $e');
    }
  }

  // â”€â”€ API Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<List<Candle>> _fetchIntradayCandles(int secId, String interval, {DateTime? date}) async {
    await RateLimiter.instance.acquire(ApiCategory.data);

    final targetDate = date ?? DateTime.now();
    final dateStr = _formatDate(targetDate);
    // Query Dhan with a 1-day buffer before the target date and filter to
    // the target locally. Dhan's intraday endpoint OMITS the pre-open
    // auction price when the query spans only a single date â€” e.g. asking
    // for 2026-05-20 alone returned FIRSTCRY 09:15 open=218.05, but the same
    // endpoint with a wider range returned open=220.73 (the auction print,
    // which Dhan's own chart UI also displays). Backtest naturally gets the
    // wide-range shape via bulkFetch's 90-day windows, so its R8-Gap saw the
    // auction-inclusive open; live's single-day fetch did not, and the two
    // disagreed on every day-open-sensitive rule. Verified against the API
    // and Dhan chart screenshot 2026-05-20 (FIRSTCRY, TVSMOTOR).
    final priorDate = targetDate.subtract(const Duration(days: 1));
    final fromStr = '${_formatDate(priorDate)} 09:15:00';
    final toStr = '$dateStr 15:30:00';
    final maxRetries = 3;
    var retryDelay = 2000;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await http.post(
          Uri.parse('https://api.dhan.co/v2/charts/intraday'),
          headers: {
            'access-token': accessToken,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'securityId': secId.toString(),
            'exchangeSegment': 'NSE_EQ',
            'instrument': 'EQUITY',
            'interval': interval,
            'oi': false,
            'fromDate': fromStr,
            'toDate': toStr,
          }),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 400) return []; // No data for this date (holiday etc.)
        if (response.statusCode == 429 && attempt < maxRetries) {
          _logOnce('Engine', 'WARN: Rate limited (429) on candle fetch, retrying...', 'rate_429');
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
          continue;
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          _logOnce('Engine', 'ERROR: Auth failed (${response.statusCode}) fetching candles â€” access token may be expired. Body: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}', 'auth_fail');
          return [];
        }
        // Dhan error 805 â€” too many requests
        if (response.statusCode != 200) {
          try {
            final errBody = jsonDecode(response.body);
            final errCode = errBody is Map ? errBody['errorCode']?.toString() : null;
            if ((errCode == '805' || errCode == 'DH-904') && attempt < maxRetries) {
              _logOnce('Engine', 'WARN: Dhan error $errCode, retrying...', 'dhan_$errCode');
              await Future.delayed(Duration(milliseconds: retryDelay));
              retryDelay *= 2;
              continue;
            }
            // Log unexpected API errors
            _logOnce('Engine', 'ERROR: Candle API HTTP ${response.statusCode} for secId=$secId date=$dateStr â€” ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}', 'http_${response.statusCode}');
          } catch (_) {
            _logOnce('Engine', 'ERROR: Candle API HTTP ${response.statusCode} for secId=$secId date=$dateStr (unparseable body)', 'http_${response.statusCode}');
          }
          return [];
        }

        // Filter to the requested date â€” the 2-day query above returns
        // the prior day's candles too (needed only so Dhan includes the
        // auction print at target-date 09:15); callers expect a single
        // day's bars.
        final parsed = _parseCandles(response.body);
        return parsed
            .where((c) => _formatDate(c.date) == dateStr)
            .toList();
      } catch (e) {
        if (attempt == maxRetries) {
          _logOnce('Engine', 'ERROR: Candle fetch failed after $maxRetries retries for secId=$secId date=$dateStr: $e', 'fetch_exception');
        } else {
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
        }
      }
    }

    return [];
  }

  /// Fetch LTP for a batch of security IDs using OHLC endpoint.
  Future<Map<int, double>> _fetchLtpBatch(List<int> securityIds) async {
    if (securityIds.isEmpty) return {};
    await RateLimiter.instance.acquire(ApiCategory.quote);

    try {
      final response = await http.post(
        Uri.parse('https://api.dhan.co/v2/marketfeed/ohlc'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'NSE_EQ': securityIds}),
      ).timeout(const Duration(seconds: 15));
      // Without this timeout a half-open/stuck TCP connection (e.g. a network
      // glitch) makes `await http.post` hang FOREVER, which froze the exit
      // monitor's poll loop — a position then never reached its 15:00 square-off
      // (observed 2026-06-18: CCL entered but never exited, run hung till manual
      // stop). On timeout this throws → caught below → returns {} → the monitor
      // simply skips this poll and keeps going, still squaring off at 15:00.

      if (response.statusCode != 200) return {};

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final nseData = json['data']?['NSE_EQ'] as Map<String, dynamic>? ?? {};

      return {
        for (final entry in nseData.entries)
          if (int.tryParse(entry.key) != null)
            int.parse(entry.key): (entry.value['last_price'] as num?)?.toDouble() ?? 0,
      };
    } catch (e) {
      _log('Engine', 'LTP batch fetch error: $e');
      return {};
    }
  }

  List<Candle> _parseCandles(String body) {
    final json = jsonDecode(body);
    final opens = (json['open'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final highs = (json['high'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final lows = (json['low'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final closes = (json['close'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final volumes = (json['volume'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final timestamps = (json['timestamp'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [];

    if (opens.isEmpty) return [];

    const marketOpenMinutes = 9 * 60 + 15;
    const marketCloseMinutes = 15 * 60 + 30;

    final candles = <Candle>[];
    for (int i = 0; i < opens.length; i++) {
      final dt = DateTime.fromMillisecondsSinceEpoch(timestamps[i] * 1000);
      final minuteOfDay = dt.hour * 60 + dt.minute;
      if (minuteOfDay < marketOpenMinutes || minuteOfDay > marketCloseMinutes) continue;

      candles.add(Candle(
        date: dt,
        high: highs[i],
        low: lows[i],
        open: opens[i],
        close: closes[i],
        volume: i < volumes.length ? volumes[i] : 0,
      ));
    }

    // Parse boundary — every API response is sanitized (dedupe + validity)
    // before any strategy logic sees it. See CandleSanitizer.
    final clean = CandleSanitizer.sanitize(candles, context: 'live intraday');
    // candlesticks package expects newest first
    return clean.reversed.toList();
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // â”€â”€ Logging & Updates â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _log(String tag, String msg) {
    debugPrint('[$tag] $msg');
    try {
      // Write to file so user can share logs for debugging
      if (tag == 'Engine' && (msg.contains('DOMINANCE') || msg.contains('BREAKOUT') || msg.contains('TRADE') || msg.contains('SL HIT') || msg.contains('TARGET'))) {
        AppLogger.strategy(msg);
      } else if (tag == 'Engine' && msg.contains('ORDER')) {
        AppLogger.trade(msg);
      } else {
        AppLogger.info(tag, msg);
      }
    } catch (_) {}
    // Mirror every engine line into the per-run JSONL so the run log is a
    // complete forensic record. Structured payloads (SCAN, FETCH, WHY ZERO)
    // emit their own _runLog entries with the `data` field â€” those calls
    // intentionally remain alongside this mirror for richer detail.
    try {
      final level = msg.startsWith('ERROR') || msg.startsWith('FATAL')
          ? 'error'
          : msg.startsWith('WARN') || msg.startsWith('CRITICAL')
              ? 'warn'
              : 'info';
      if (level == 'error') {
        _runLog?.error(tag, msg);
      } else if (level == 'warn') {
        _runLog?.warn(tag, msg);
      } else {
        _runLog?.info(tag, msg);
      }
    } catch (_) {}
  }

  /// Log a message only once per key â€” prevents log spam during pre-market loading
  final _loggedOnce = <String>{};
  void _logOnce(String tag, String msg, String key) {
    if (_loggedOnce.contains(key)) return;
    _loggedOnce.add(key);
    _log(tag, msg);
  }

  void _sendUpdate(String event, Map<String, dynamic> data) {
    try {
      onUpdate(event, data);
    } catch (_) {}
  }
}

/// Façade over [StrategyEngine] handed to self-contained strategies so they can
/// drive a full live/paper session without touching engine internals.
class _LiveEngineCtx implements LiveEngineContext {
  final StrategyEngine _e;
  _LiveEngineCtx(this._e);

  @override
  Map<String, dynamic> get params => _e.config.params;
  @override
  List<int> get securityIds => _e._securityIds;
  @override
  ScripService get scripService => _e._scripService;
  @override
  String get accessToken => _e.accessToken;
  @override
  String get clientId => _e.clientId;
  @override
  String get configId => _e.config.id;
  @override
  bool get isPaperTrading => _e.config.paperTrading;
  @override
  bool get stopRequested => _e._stopRequested;
  @override
  int get tradesPlacedToday => _e._tradesPlacedToday;

  @override
  Future<List<Candle>> fetchIntraday(int securityId, String interval,
          {DateTime? date}) =>
      _e._fetchIntradayCandles(securityId, interval, date: date);
  @override
  Future<Map<int, double>> fetchLtpBatch(List<int> securityIds) =>
      _e._fetchLtpBatch(securityIds);
  @override
  Future<void> placeLiveOrder(StrategyTradeModel trade) =>
      _e._placeLiveOrder(trade);

  @override
  void log(String message) => _e._log('Engine', message);
  @override
  void addKeyEvent(String event) => _e._addKeyEvent(event);
  @override
  void runLogInfo(String tag, String message, [Map<String, dynamic>? data]) =>
      _e._runLog?.info(tag, message, data);
  @override
  void sendUpdate(String event, Map<String, dynamic> data) =>
      _e._sendUpdate(event, data);

  @override
  void recordSignal() => _e._totalSignalsGenerated++;
  @override
  void recordTrade(StrategyTradeModel trade) {
    _e._trades.add(trade);
    _e._tradesPlacedToday++;
  }

  @override
  void recordActiveStocks(int count) => _e._customActiveStocks = count;
}

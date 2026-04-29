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
import '../services/rate_limiter.dart';
import '../services/scrip_service.dart';
import '../services/storage_service.dart';
import '../strategies/dominance_breakout_strategy.dart';

/// Callback to send status updates back to the UI (via background service).
typedef EngineCallback = void Function(String event, Map<String, dynamic> data);

/// The Strategy Engine — orchestrates the complete trading workflow:
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
/// in isolate — Dhan WebSocket needs single connection, REST is simpler here).
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
  bool _running = false;
  bool _stopRequested = false;
  String _startTime = '';
  final List<String> _keyEvents = [];

  // Nifty 500 security IDs loaded from scrip master
  List<int> _securityIds = [];

  // API rate limiting — uses global RateLimiter.instance

  StrategyEngine({
    required this.clientId,
    required this.accessToken,
    required this.config,
    required this.onUpdate,
  });

  bool get isRunning => _running;

  /// Main entry point — runs the complete strategy workflow.
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

      _log('Engine', '═══ STRATEGY ENGINE STARTING ═══');
      _log('Engine', 'Strategy: ${config.name}');
      _log('Engine', 'Mode: ${config.paperTrading ? "PAPER" : "LIVE"}');
      _log('Engine', 'Config ID: ${config.id}');
      _addKeyEvent('Engine started (${config.paperTrading ? "Paper" : "Live"})');

      _sendUpdate('phase', {'phase': 'loading', 'message': 'Loading instruments...'});

      // Step 1: Load scrip master and get Nifty 500 IDs
      await _loadInstruments();
      if (_stopRequested) { endStatus = 'stopped'; return; }

      _addKeyEvent('Loaded ${_securityIds.length} instruments');

      // Step 2: Pre-market data loading (historical candles → metrics)
      _sendUpdate('phase', {'phase': 'preparing', 'message': 'Loading historical data...'});
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

      // Step 4: Generate summary
      _generateSummary();

      _log('Engine', '═══ STRATEGY ENGINE COMPLETE ═══');
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
    }
  }

  /// Stop the engine gracefully.
  void stop() {
    _log('Engine', 'Stop requested');
    _stopRequested = true;
    _running = false;
  }

  // ── Step 1: Load Instruments ──────────────────────────────────────────

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

  // ── Step 2: Pre-Market Data Loading ───────────────────────────────────

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
      if (_loggedOnce.contains('auth_fail')) causes.add('ACCESS TOKEN EXPIRED — generate a new token on Dhan developer portal');
      if (_loggedOnce.contains('rate_429') || _loggedOnce.contains('dhan_805') || _loggedOnce.contains('dhan_DH-904')) causes.add('RATE LIMITED — too many API calls, try increasing delay');
      if (_loggedOnce.contains('fetch_exception')) causes.add('NETWORK ERROR — check internet connection');
      if (causes.isEmpty) causes.add('ALL DATES RETURNED EMPTY — possible market holiday week or API issue');

      _log('Engine', 'CRITICAL: ALL $failed stocks failed pre-market data load! 0 candidates will be found.');
      _log('Engine', 'CRITICAL: Root cause: ${causes.join(" | ")}');
      _log('Engine', 'CRITICAL: FIX → ${causes.first.split(" — ").last}');
    }

    // Remove security IDs that have no metrics
    _securityIds = _securityIds.where((id) => _stockMetrics.containsKey(id)).toList();
  }

  Future<CandleStatsModel?> _loadStockMetrics(int secId, String symbol, int days) async {
    final allCandles = <Candle>[];
    final today = DateTime.now();

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
          allCandles.addAll(candles.reversed); // oldest first
          fetched++;
        } else {
          emptyDays++;
        }
      } catch (e) {
        errorDays++;
      }
    }

    if (allCandles.isEmpty) {
      // Only log first stock's breakdown to avoid spam — _logOnce ensures one entry
      _logOnce('Engine',
          'DEBUG: First stock failure breakdown — $symbol: emptyDays=$emptyDays, errorDays=$errorDays, daysChecked=$daysBack '
          '(empty=API returned no candles for that date, error=network/API exception)',
          'first_stock_fail');
      return null;
    }

    final avgVolume = allCandles.fold<double>(0, (sum, c) => sum + c.volume) / allCandles.length;
    final avgCandleSize = allCandles.fold<double>(0, (sum, c) => sum + (c.high - c.low)) / allCandles.length;
    final prevClose = allCandles.last.close;

    return CandleStatsModel(
      securityId: secId,
      symbol: symbol,
      avgCandleSize: avgCandleSize,
      avgVolume: avgVolume,
      prevClose: prevClose,
      totalCandles: allCandles.length,
    );
  }

  // ── Step 3: Progressive Candle Fetching & Screening ───────────────────

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
      final toRemove = <int>[];

      for (final secId in activeIds) {
        if (_stopRequested) return;

        try {
          final candles = await _fetchIntradayCandles(secId, '5', date: today);
          if (candles.isEmpty) {
            toRemove.add(secId);
            elimNoData++;
            continue;
          }

          // Store candles (oldest first)
          _todayCandles[secId] = candles.reversed.toList();

          // Store day open price
          if (!_dayOpenPrices.containsKey(secId) && _todayCandles[secId]!.isNotEmpty) {
            _dayOpenPrices[secId] = _todayCandles[secId]!.first.open;
          }

          // Volume filter: latest candle must have >= minAbsoluteVolume
          final latestCandle = _todayCandles[secId]!.last;
          if (latestCandle.volume < minAbsoluteVolume) {
            toRemove.add(secId);
            elimLowVol++;
          }
        } catch (e) {
          toRemove.add(secId);
          elimApiErr++;
        }
      }

      // Remove eliminated stocks and log summary
      final totalElim = elimNoData + elimLowVol + elimApiErr;
      if (toRemove.isNotEmpty) {
        activeIds.removeWhere((id) => toRemove.contains(id));
        _log('Engine',
          'Eliminated $totalElim stocks at ${screenTime.hour}:${screenTime.minute.toString().padLeft(2, "0")} '
          '— LowVolume: $elimLowVol, NoData: $elimNoData, ApiError: $elimApiErr. '
          'Remaining: ${activeIds.length}');
        _addKeyEvent('Eliminated $totalElim (Vol:$elimLowVol NoData:$elimNoData Err:$elimApiErr) → ${activeIds.length} remaining');
      }

      // Screen for dominance candles (only from scanStartTime onwards, C#: 9:35)
      final screenTimeOfDay = Duration(hours: screenTime.hour, minutes: screenTime.minute);
      if (screenTimeOfDay >= scanStartTime) {
        _log('Engine', 'Screening for dominance candles...');
        _screenForDominance();

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

  // ── Dominance Candle Screening ────────────────────────────────────────

  void _screenForDominance() {
    final strategy = DominanceBreakoutStrategy();

    final signals = strategy.scan(
      configId: config.id,
      stats: _stockMetrics,
      todayCandles: _todayCandles,
      params: config.params,
      scripService: _scripService,
      alreadySignalled: _alreadySignalled,
      debugLog: (msg) => _log('Scan', msg),
    );

    final maxTrades = (config.params['maxTradesPerDay'] as num?)?.toInt() ?? 2;

    for (final signal in signals) {
      _alreadySignalled.add(signal.securityId);
      _totalSignalsGenerated++;
      final sigTime = '${signal.timestamp.hour.toString().padLeft(2, '0')}:${signal.timestamp.minute.toString().padLeft(2, '0')}';
      final expTime = '${signal.expiryTime.hour.toString().padLeft(2, '0')}:${signal.expiryTime.minute.toString().padLeft(2, '0')}';
      _log('Engine', 'DOMINANCE FOUND: ${signal.symbol} Break=${signal.entryPrice} SL=${signal.stopLoss} Window=$sigTime→$expTime');
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

  // ── Breakout Monitoring (REST LTP polling) ────────────────────────────

  Future<void> _monitorBreakouts() async {
    if (_activeSignals.isEmpty) return;
    if (_stopRequested) return;

    final maxTrades = (config.params['maxTradesPerDay'] as num?)?.toInt() ?? 2;
    if (_tradesPlacedToday >= maxTrades) {
      _log('Engine', 'Max trades ($maxTrades) reached — skipping breakout monitor');
      return;
    }

    // Poll LTP for active signals using OHLC endpoint
    final signalSecIds = _activeSignals.map((s) => s.securityId).toList();

    _log('Engine', 'Monitoring LTP for ${signalSecIds.length} candidates...');

    try {
      final ltpMap = await _fetchLtpBatch(signalSecIds);

      for (final signal in List.of(_activeSignals)) {
        final ltp = ltpMap[signal.securityId];
        if (ltp == null || ltp <= 0) continue;

        // Check if LTP > dominance high (breakout!)
        if (ltp > signal.entryPrice) {
          _log('Engine', 'BREAKOUT: ${signal.symbol} LTP=$ltp > Entry=${signal.entryPrice}');

          // Calculate trade (position sizing)
          final trade = _calculateTrade(signal, ltp);
          if (trade != null) {
            _trades.add(trade);
            _tradesPlacedToday++;
            _activeSignals.remove(signal);

            _log('Engine', 'TRADE: ${trade.symbol} Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss} Target=${trade.target}');
            _addKeyEvent('TRADE: ${trade.symbol} Qty=${trade.quantity} @ ${trade.entryPrice}');

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

            // Place live order if not paper
            if (!config.paperTrading) {
              await _placeLiveOrder(trade);
            }
          }
        }

        // Check expiry
        if (DateTime.now().isAfter(signal.expiryTime)) {
          _log('Engine', 'EXPIRED: ${signal.symbol} — no breakout before ${signal.expiryTime}, can be re-screened');
          _activeSignals.remove(signal);
          _alreadySignalled.remove(signal.securityId); // Can be re-screened
        }
      }
    } catch (e) {
      _log('Engine', 'LTP fetch error: $e');
    }
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

  // ── Monitor Open Positions ────────────────────────────────────────────

  Future<void> _monitorOpenPositions() async {
    final marketClose = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      15, 15, // 3:15 PM — square off time
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
            _log('Engine', 'SL HIT: ${trade.symbol} @ ${trade.stopLoss}');
            _sendTradeUpdate(trade, 'sl_hit');
          }
          // Check target
          else if (ltp >= trade.target) {
            trade.status = TradeStatus.closed;
            trade.exitPrice = trade.target;
            trade.exitTime = DateTime.now();
            trade.outcome = TradeOutcome.target;
            _log('Engine', 'TARGET HIT: ${trade.symbol} @ ${trade.target}');
            _sendTradeUpdate(trade, 'target_hit');
          }
        }
      } catch (e) {
        _log('Engine', 'Position monitor error: $e');
      }

      // Poll every 3 seconds
      await Future.delayed(const Duration(seconds: 3));
    }

    // Square off remaining positions at market close
    final remaining = _trades.where((t) => t.status == TradeStatus.open).toList();
    if (remaining.isNotEmpty && !_stopRequested) {
      _log('Engine', 'Market closing — squaring off ${remaining.length} positions');
      for (final trade in remaining) {
        trade.status = TradeStatus.closed;
        trade.exitPrice = trade.entryPrice; // Will be updated with actual LTP
        trade.exitTime = DateTime.now();
        trade.outcome = TradeOutcome.endOfDay;
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

  // ── Live Order Placement ──────────────────────────────────────────────

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
      );

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

  // ── Summary ───────────────────────────────────────────────────────────

  void _generateSummary() {
    final totalTrades = _trades.length;
    final winners = _trades.where((t) => t.pnl > 0).length;
    final losers = _trades.where((t) => t.pnl < 0).length;
    final totalPnl = _trades.fold<double>(0, (sum, t) => sum + t.pnl);

    _log('Engine', '═══ END OF DAY SUMMARY ═══');
    _log('Engine', 'Dominance Candidates: ${_alreadySignalled.length}');
    _log('Engine', 'Total Trades: $totalTrades');
    _log('Engine', 'Winners: $winners | Losers: $losers');
    _log('Engine', 'Total P&L: Rs ${totalPnl.toStringAsFixed(2)}');
    _log('Engine', '═══════════════════════════');
  }

  // ── Save trades to SharedPreferences ──────────────────────────────────

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

  // ── Key Events (for daily history) ──────────────────────────────────

  void _addKeyEvent(String event) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}';
    _keyEvents.add('[$ts] $event');
    // Keep max 50 events
    if (_keyEvents.length > 50) _keyEvents.removeAt(0);
  }

  // ── Save Daily Run Summary ─────────────────────────────────────────

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
        finalActiveStocks: _stockMetrics.length,
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

  // ── API Helpers ───────────────────────────────────────────────────────

  Future<List<Candle>> _fetchIntradayCandles(int secId, String interval, {DateTime? date}) async {
    await RateLimiter.instance.acquire(ApiCategory.data);

    final dateStr = _formatDate(date ?? DateTime.now());
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
            'fromDate': '$dateStr 09:15:00',
            'toDate': '$dateStr 15:30:00',
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
          _logOnce('Engine', 'ERROR: Auth failed (${response.statusCode}) fetching candles — access token may be expired. Body: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}', 'auth_fail');
          return [];
        }
        // Dhan error 805 — too many requests
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
            _logOnce('Engine', 'ERROR: Candle API HTTP ${response.statusCode} for secId=$secId date=$dateStr — ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}', 'http_${response.statusCode}');
          } catch (_) {
            _logOnce('Engine', 'ERROR: Candle API HTTP ${response.statusCode} for secId=$secId date=$dateStr (unparseable body)', 'http_${response.statusCode}');
          }
          return [];
        }

        return _parseCandles(response.body);
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
      );

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

    // candlesticks package expects newest first
    return candles.reversed.toList();
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Logging & Updates ─────────────────────────────────────────────────

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
  }

  /// Log a message only once per key — prevents log spam during pre-market loading
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

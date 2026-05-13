import 'package:candlesticks/candlesticks.dart';
import 'package:uuid/uuid.dart';
import '../models/candle_stats_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/dhan_feed_service.dart';
import '../services/scrip_service.dart';
import 'base_strategy.dart';

/// Exact port of C# LiveDominanceCandleScreener + LiveBreakoutEntryStrategy + BreakoutMonitor.
/// 8 dominance candle rules, breakout entry with fixed rupee risk/reward.
class DominanceBreakoutStrategy extends BaseStrategy {
  @override
  String get type => 'dominance_breakout';

  @override
  String get displayName => 'Dominance + Breakout';

  @override
  String get description =>
      'Detects high-conviction bullish candles (8 rules) and enters on LTP breakout above dominance high. Fixed ₹ risk/reward.';

  @override
  Map<String, dynamic> get defaultParams => {
        // Pre-market
        'historicalDays': 10,
        'candleInterval': '5',
        // Screening window
        'scanStartHour': 9,
        'scanStartMin': 30,
        'scanEndHour': 10,
        'scanEndMin': 0,
        'scanIntervalMinutes': 5,
        // Dominance candle rules (exact C# defaults)
        'minBodyPercent': 70.0,
        'maxBodyPercent': 85.0,
        'minWickPercent': 5.0,
        'minCandleSizeMultiplier': 1.0,
        'maxCandleSizeMultiplier': 2.5,
        'minVolumeMultiplier': 2.0,
        'minAbsoluteVolume': 5000,
        'maxMovementMultiplier': 2.0,
        'maxGapUpPercent': 2.5,
        'maxGapDownPercent': 1.0,
        // Position sizing
        'fixedStopLoss': 500.0,
        'fixedTarget': 2000.0,
        'maxTradesPerDay': 2,
      };

  @override
  List<StrategyParamDef> get paramDefinitions => [
        // Screening window
        const StrategyParamDef(
          key: 'scanStartHour',
          label: 'Scan Start Hour',
          type: ParamType.integer,
          defaultValue: 9,
          min: 9,
          max: 15,
          group: 'Screening Window',
        ),
        const StrategyParamDef(
          key: 'scanStartMin',
          label: 'Scan Start Minute',
          type: ParamType.integer,
          defaultValue: 30,
          min: 0,
          max: 59,
          group: 'Screening Window',
        ),
        const StrategyParamDef(
          key: 'scanEndHour',
          label: 'Scan End Hour',
          type: ParamType.integer,
          defaultValue: 10,
          min: 9,
          max: 15,
          group: 'Screening Window',
        ),
        const StrategyParamDef(
          key: 'scanEndMin',
          label: 'Scan End Minute',
          type: ParamType.integer,
          defaultValue: 0,
          min: 0,
          max: 59,
          group: 'Screening Window',
        ),
        const StrategyParamDef(
          key: 'scanIntervalMinutes',
          label: 'Scan Interval',
          type: ParamType.integer,
          defaultValue: 5,
          min: 1,
          max: 30,
          unit: 'min',
          group: 'Screening Window',
        ),
        // Dominance candle rules
        const StrategyParamDef(
          key: 'minBodyPercent',
          label: 'Min Body %',
          description: 'Candle body must be at least this % of range',
          type: ParamType.decimal,
          defaultValue: 70.0,
          min: 50.0,
          max: 95.0,
          unit: '%',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'maxBodyPercent',
          label: 'Max Body %',
          description: 'Candle body must be at most this % of range',
          type: ParamType.decimal,
          defaultValue: 85.0,
          min: 50.0,
          max: 95.0,
          unit: '%',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'minWickPercent',
          label: 'Min Wick %',
          description: 'Both upper and lower wick must be >= this %',
          type: ParamType.decimal,
          defaultValue: 5.0,
          min: 1.0,
          max: 20.0,
          unit: '%',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'minCandleSizeMultiplier',
          label: 'Min Candle Size',
          description: 'Candle range must be >= this x average',
          type: ParamType.decimal,
          defaultValue: 1.0,
          min: 0.5,
          max: 5.0,
          unit: 'x',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'maxCandleSizeMultiplier',
          label: 'Max Candle Size',
          description: 'Candle range must be <= this x average',
          type: ParamType.decimal,
          defaultValue: 2.5,
          min: 1.0,
          max: 10.0,
          unit: 'x',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'minVolumeMultiplier',
          label: 'Volume Multiplier',
          description: 'Volume must be >= this x average volume',
          type: ParamType.decimal,
          defaultValue: 2.0,
          min: 1.0,
          max: 10.0,
          unit: 'x',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'minAbsoluteVolume',
          label: 'Min Absolute Volume',
          description:
              'All candles from 9:15 to dominance candle must have >= this volume',
          type: ParamType.integer,
          defaultValue: 5000,
          min: 100,
          max: 100000,
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'maxMovementMultiplier',
          label: 'Max Movement',
          description:
              'Actual price movement must be <= this x expected movement',
          type: ParamType.decimal,
          defaultValue: 2.0,
          min: 1.0,
          max: 5.0,
          unit: 'x',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'maxGapUpPercent',
          label: 'Max Gap Up %',
          description: 'Day open gap up must be <= this %',
          type: ParamType.decimal,
          defaultValue: 2.5,
          min: 0.5,
          max: 10.0,
          unit: '%',
          group: 'Dominance Rules',
        ),
        const StrategyParamDef(
          key: 'maxGapDownPercent',
          label: 'Max Gap Down %',
          description: 'Day open gap down must be <= this %',
          type: ParamType.decimal,
          defaultValue: 1.0,
          min: 0.5,
          max: 10.0,
          unit: '%',
          group: 'Dominance Rules',
        ),
        // Pre-market
        const StrategyParamDef(
          key: 'historicalDays',
          label: 'Historical Days',
          description: 'Number of past days for computing averages',
          type: ParamType.integer,
          defaultValue: 10,
          min: 3,
          max: 30,
          group: 'Pre-Market Data',
        ),
        // Position sizing
        const StrategyParamDef(
          key: 'fixedStopLoss',
          label: 'Risk per Trade',
          description: 'Fixed rupee amount to risk per trade',
          type: ParamType.decimal,
          defaultValue: 500.0,
          min: 100.0,
          max: 10000.0,
          unit: 'INR',
          group: 'Position Sizing',
        ),
        const StrategyParamDef(
          key: 'fixedTarget',
          label: 'Target per Trade',
          description: 'Fixed rupee amount target profit per trade',
          type: ParamType.decimal,
          defaultValue: 2000.0,
          min: 100.0,
          max: 50000.0,
          unit: 'INR',
          group: 'Position Sizing',
        ),
        const StrategyParamDef(
          key: 'maxTradesPerDay',
          label: 'Max Trades / Day',
          description: 'Maximum number of trades per day',
          type: ParamType.integer,
          defaultValue: 2,
          min: 1,
          max: 10,
          group: 'Position Sizing',
        ),
      ];

  @override
  String? diagnosisHint(String rule) {
    if (rule.startsWith('R1')) return 'All candles bearish — flat/down day.';
    if (rule.startsWith('R2')) return 'Body % outside 70-85 — relax bounds or check candle data.';
    if (rule.startsWith('R3')) return 'Wicks too small — pure-body candles, not dominance shape.';
    if (rule.startsWith('R4')) return 'Candle size outside 1-2.5×avg — calm or volatile day.';
    if (rule.startsWith('R5')) return 'Volume < 2×avg — quiet session OR partial-candle data at fetch time.';
    if (rule.startsWith('R6a')) return 'Candle vol < 5000 — illiquid OR partial-candle data.';
    if (rule.startsWith('R6b')) return 'A prior candle since 9:15 had vol < 5000 — choppy opening.';
    if (rule.startsWith('R7')) return 'Cumulative move too large vs avg — gappy/runaway day.';
    if (rule.startsWith('R8')) return 'Gap up/down outside +2.5%/-1% — overnight news / gap day.';
    return null;
  }

  // ── Phase 1: Prepare (Pre-Market) ──────────────────────────────────────

  @override
  Future<Map<int, CandleStatsModel>> prepare({
    required List<int> securityIds,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Future<List<Candle>> Function(int securityId, String interval,
            {DateTime? date})
        fetchIntraday,
    required void Function(int completed, int total) onProgress,
  }) async {
    final days = (params['historicalDays'] as num?)?.toInt() ?? 10;
    final interval = params['candleInterval'] as String? ?? '5';
    final results = <int, CandleStatsModel>{};

    for (int i = 0; i < securityIds.length; i++) {
      final secId = securityIds[i];
      final scrip = scripService.findById(secId);
      final symbol = scrip?.symbol ?? secId.toString();

      try {
        final allCandles = <Candle>[];
        final today = DateTime.now();

        // Fetch last N trading days of 5-min candles
        int fetched = 0;
        int daysBack = 0;
        while (fetched < days && daysBack < days + 15) {
          daysBack++;
          final date = today.subtract(Duration(days: daysBack));
          // Skip weekends
          if (date.weekday == DateTime.saturday ||
              date.weekday == DateTime.sunday) continue;

          try {
            final candles =
                await fetchIntraday(secId, interval, date: date);
            if (candles.isNotEmpty) {
              // candlesticks package returns newest first, we want oldest first
              allCandles.addAll(candles.reversed);
              fetched++;
            }
          } catch (_) {
            // Skip failed days (holidays, no data)
          }
        }

        if (allCandles.isEmpty) continue;

        // Compute metrics (exact C# logic)
        final avgVolume = allCandles.fold<double>(
                0, (sum, c) => sum + c.volume) /
            allCandles.length;
        final avgCandleSize = allCandles.fold<double>(
                0, (sum, c) => sum + (c.high - c.low)) /
            allCandles.length;
        // prevClose = last candle's close (most recent)
        final prevClose = allCandles.last.close;

        results[secId] = CandleStatsModel(
          securityId: secId,
          symbol: symbol,
          avgCandleSize: avgCandleSize,
          avgVolume: avgVolume,
          prevClose: prevClose,
          totalCandles: allCandles.length,
        );
      } catch (_) {
        // Skip this stock
      }

      onProgress(i + 1, securityIds.length);
    }

    return results;
  }

  // ── Phase 2: Scan (Dominance Candle Detection) ─────────────────────────

  @override
  List<StrategySignalModel> scan({
    required String configId,
    required Map<int, CandleStatsModel> stats,
    required Map<int, List<Candle>> todayCandles,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Set<int> alreadySignalled,
    void Function(String message)? debugLog,
    void Function(ScanReport report)? onScanReport,
  }) {
    final signals = <StrategySignalModel>[];
    final p = _Params(params);
    // Reject counts are always tracked (cheap) so the engine can surface a
    // structured ScanReport even when verbose debugLog is disabled.
    final rejectCounts = <String, int>{};
    int stocksEvaluated = 0;
    int candlesInWindow = 0;

    // Build screening window from params (matches C#: IsActiveAt check)
    final scanStart = Duration(
      hours: (params['scanStartHour'] as num?)?.toInt() ?? 9,
      minutes: (params['scanStartMin'] as num?)?.toInt() ?? 30,
    );
    final scanEnd = Duration(
      hours: (params['scanEndHour'] as num?)?.toInt() ?? 10,
      minutes: (params['scanEndMin'] as num?)?.toInt() ?? 0,
    );

    for (final entry in todayCandles.entries) {
      final secId = entry.key;
      final candles = entry.value; // oldest first (9:15 → latest)

      // Skip if already has a signal (C#: _activeCandidates.ContainsKey)
      if (alreadySignalled.contains(secId)) continue;

      // Skip if no stats
      final stat = stats[secId];
      if (stat == null) continue;

      if (candles.isEmpty) continue;
      stocksEvaluated++;

      // C# processes EVERY candle via ProcessCandle and checks IsActiveAt.
      // We iterate all candles in the screening window; first match wins.
      for (final candle in candles) {
        // C#: IsActiveAt(candle.Timestamp) — only candles in screening window
        final candleTime = Duration(
            hours: candle.date.hour, minutes: candle.date.minute);
        if (candleTime < scanStart || candleTime > scanEnd) continue;
        candlesInWindow++;

        final result = _isDominanceCandle(candle, candles, stat, p,
          onReject: (sym, rule, detail) {
            rejectCounts[rule] = (rejectCounts[rule] ?? 0) + 1;
            debugLog?.call(
                'REJECT $sym @${candle.date.hour}:${candle.date.minute.toString().padLeft(2, "0")} $rule: $detail');
          },
        );

        if (result != null) {
          final scrip = scripService.findById(secId);
          final symbol = scrip?.symbol ?? secId.toString();

          // Compute expiry = next scan interval boundary
          final now = DateTime.now();
          final scanMins = p.scanIntervalMinutes;
          final nextMin = ((now.minute ~/ scanMins) + 1) * scanMins;
          final expiry = DateTime(now.year, now.month, now.day, now.hour, 0)
              .add(Duration(minutes: nextMin));

          signals.add(StrategySignalModel(
            id: const Uuid().v4(),
            strategyConfigId: configId,
            securityId: secId,
            symbol: symbol,
            type: SignalType.dominanceCandle,
            timestamp: DateTime.now(),
            entryPrice: candle.high, // C#: EntryPrice = candle.High
            stopLoss: candle.low, // C#: StopLoss = candle.Low
            expiryTime: expiry,
            candleOpen: candle.open,
            candleHigh: candle.high,
            candleLow: candle.low,
            candleClose: candle.close,
            candleVolume: candle.volume,
            bodyPercent: result.bodyPercent,
            upperWickPercent: result.upperWickPercent,
            lowerWickPercent: result.lowerWickPercent,
            sizeMultiplier: result.sizeMultiplier,
            volumeMultiplier: result.volumeMultiplier,
            reason:
                'Dominance Found: $symbol High=${candle.high} Low=${candle.low}',
          ));
          break; // C#: one candidate per stock at a time
        }
      }
    }

    // Log rejection summary so user can see which rules are eliminating stocks
    if (debugLog != null && rejectCounts.isNotEmpty) {
      final summary = rejectCounts.entries
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      debugLog('REJECTION SUMMARY: $summary (total candles checked across ${todayCandles.length} stocks)');
    }

    // Structured report (always emitted) for downstream diagnostics.
    onScanReport?.call(ScanReport(
      stocksEvaluated: stocksEvaluated,
      candlesInWindow: candlesInWindow,
      rejectCounts: rejectCounts,
    ));

    return signals;
  }

  // ── Phase 3: Check Breakout ────────────────────────────────────────────

  @override
  StrategyTradeModel? checkBreakout({
    required FeedUpdate tick,
    required int securityId,
    required List<StrategySignalModel> activeSignals,
    required Map<String, dynamic> params,
    required int tradesPlacedToday,
    required bool isPaperTrade,
    required String configId,
  }) {
    final maxTrades = (params['maxTradesPerDay'] as num?)?.toInt() ?? 2;
    if (tradesPlacedToday >= maxTrades) return null;

    final ltp = tick.ltp;
    if (ltp <= 0) return null;

    for (final signal in activeSignals) {
      if (signal.securityId != securityId) continue;

      // C#: if (ltpDecimal > candidate.DominanceHigh)
      if (ltp > signal.entryPrice) {
        // Breakout! Calculate position sizing (exact C# logic)
        final fixedSL = (params['fixedStopLoss'] as num?)?.toDouble() ?? 500;
        final fixedTarget =
            (params['fixedTarget'] as num?)?.toDouble() ?? 2000;

        final entryPrice = signal.entryPrice; // C#: EntryPrice = DominanceHigh
        final slPrice = signal.stopLoss; // C#: StopLoss = DominanceLow
        final riskPerShare = entryPrice - slPrice;

        if (riskPerShare <= 0) continue;

        // C#: var quantity = (int)Math.Floor(fixedStopLoss / riskPerShare);
        final quantity = (fixedSL / riskPerShare).floor();
        if (quantity <= 0) continue;

        // C#: var targetPrice = entryPrice + (fixedTarget / quantity);
        final targetPrice = entryPrice + (fixedTarget / quantity);

        return StrategyTradeModel(
          id: const Uuid().v4(),
          strategyConfigId: configId,
          signalId: signal.id,
          securityId: securityId,
          symbol: signal.symbol,
          status: TradeStatus.open,
          isPaperTrade: isPaperTrade,
          entryPrice: entryPrice,
          quantity: quantity,
          entryTime: DateTime.now(),
          stopLoss: slPrice,
          target: targetPrice,
        );
      }
    }

    return null;
  }

  // ── Phase 4: Check Exit ────────────────────────────────────────────────

  @override
  StrategyTradeModel? checkExit({
    required FeedUpdate tick,
    required StrategyTradeModel trade,
  }) {
    if (trade.status != TradeStatus.open) return null;
    final ltp = tick.ltp;
    if (ltp <= 0) return null;

    if (ltp <= trade.stopLoss) {
      trade.status = TradeStatus.closed;
      trade.exitPrice = trade.stopLoss;
      trade.exitTime = DateTime.now();
      trade.outcome = TradeOutcome.stopLoss;
      return trade;
    }

    if (ltp >= trade.target) {
      trade.status = TradeStatus.closed;
      trade.exitPrice = trade.target;
      trade.exitTime = DateTime.now();
      trade.outcome = TradeOutcome.target;
      return trade;
    }

    return null;
  }

  // ── Private: Dominance candle detection (exact C# port) ────────────────

  _DominanceMetrics? _isDominanceCandle(
    Candle candle,
    List<Candle> intradayCandles, // oldest first
    CandleStatsModel stats,
    _Params p, {
    void Function(String symbol, String rule, String detail)? onReject,
  }) {
    final sym = stats.symbol;
    final range = candle.high - candle.low;
    if (range <= 0) return null;

    // RULE 1: Must be bullish
    final body = candle.close - candle.open;
    if (body <= 0) {
      onReject?.call(sym, 'R1-Bullish', 'body=${body.toStringAsFixed(2)} (bearish)');
      return null;
    }

    // RULE 2: Body percentage (70-85% of range)
    final bodyPercent = (body / range) * 100;
    if (bodyPercent < p.minBodyPercent || bodyPercent > p.maxBodyPercent) {
      onReject?.call(sym, 'R2-Body%', '${bodyPercent.toStringAsFixed(1)}% not in ${p.minBodyPercent}-${p.maxBodyPercent}%');
      return null;
    }

    // RULE 3: Both wicks must be >= minWickPercent
    final upperWick = candle.high - candle.close;
    final lowerWick = candle.open - candle.low;
    final upperWickPercent = (upperWick / range) * 100;
    final lowerWickPercent = (lowerWick / range) * 100;

    if (!(upperWickPercent >= p.minWickPercent &&
        lowerWickPercent >= p.minWickPercent)) {
      onReject?.call(sym, 'R3-Wick%', 'upper=${upperWickPercent.toStringAsFixed(1)}% lower=${lowerWickPercent.toStringAsFixed(1)}% (need >=${p.minWickPercent}%)');
      return null;
    }

    // RULE 4: Candle size between min and max multiplier of average
    final avgCandleSize = stats.avgCandleSize;
    if (avgCandleSize <= 0) return null;

    final sizeMultiplier = range / avgCandleSize;
    if (sizeMultiplier < p.minCandleSizeMultiplier ||
        sizeMultiplier > p.maxCandleSizeMultiplier) {
      onReject?.call(sym, 'R4-Size', '${sizeMultiplier.toStringAsFixed(2)}x not in ${p.minCandleSizeMultiplier}-${p.maxCandleSizeMultiplier}x');
      return null;
    }

    // RULE 5: Volume >= minVolumeMultiplier * average volume
    final volumeMultiplier =
        stats.avgVolume > 0 ? candle.volume / stats.avgVolume : 0.0;
    if (candle.volume < stats.avgVolume * p.minVolumeMultiplier) {
      onReject?.call(sym, 'R5-VolMult', '${volumeMultiplier.toStringAsFixed(2)}x < ${p.minVolumeMultiplier}x');
      return null;
    }

    // RULE 6a: This candle's volume >= minAbsoluteVolume
    if (candle.volume < p.minAbsoluteVolume) {
      onReject?.call(sym, 'R6a-AbsVol', 'vol=${candle.volume.toInt()} < ${p.minAbsoluteVolume.toInt()}');
      return null;
    }

    // RULE 6b: ALL candles from market open till this candle must have >= minAbsoluteVolume
    final candleIndex = intradayCandles.indexWhere(
        (c) => c.date == candle.date);
    if (candleIndex >= 0) {
      for (int j = 0; j <= candleIndex; j++) {
        if (intradayCandles[j].volume < p.minAbsoluteVolume) {
          onReject?.call(sym, 'R6b-AllVol', 'candle[$j] vol=${intradayCandles[j].volume.toInt()} < ${p.minAbsoluteVolume.toInt()}');
          return null;
        }
      }
    }

    // RULE 7: Movement check — actualMovement <= maxMovementMultiplier * expected
    final dayOpen = intradayCandles.isNotEmpty
        ? intradayCandles.first.open
        : candle.open;
    final numberOfCandles = candleIndex + 1;
    final expectedMovement = numberOfCandles * avgCandleSize;
    final actualMovement = (candle.close - dayOpen).abs();

    if (actualMovement > p.maxMovementMultiplier * expectedMovement) {
      onReject?.call(sym, 'R7-Movement', 'actual=${actualMovement.toStringAsFixed(2)} > ${p.maxMovementMultiplier}x expected=${expectedMovement.toStringAsFixed(2)}');
      return null;
    }

    // RULE 8: Gap filter
    if (stats.prevClose > 0) {
      final gapPercent = ((dayOpen - stats.prevClose) / stats.prevClose) * 100;
      if (gapPercent > p.maxGapUpPercent || gapPercent < -p.maxGapDownPercent) {
        onReject?.call(sym, 'R8-Gap', 'gap=${gapPercent.toStringAsFixed(2)}% (limit: +${p.maxGapUpPercent}% / -${p.maxGapDownPercent}%)');
        return null;
      }
    }

    return _DominanceMetrics(
      bodyPercent: bodyPercent,
      upperWickPercent: upperWickPercent,
      lowerWickPercent: lowerWickPercent,
      sizeMultiplier: sizeMultiplier,
      volumeMultiplier: volumeMultiplier,
    );
  }
}

/// Helper to extract typed params.
class _Params {
  final Map<String, dynamic> _m;
  _Params(this._m);

  double get minBodyPercent => (_m['minBodyPercent'] as num?)?.toDouble() ?? 70;
  double get maxBodyPercent => (_m['maxBodyPercent'] as num?)?.toDouble() ?? 85;
  double get minWickPercent => (_m['minWickPercent'] as num?)?.toDouble() ?? 5;
  double get minCandleSizeMultiplier =>
      (_m['minCandleSizeMultiplier'] as num?)?.toDouble() ?? 1.0;
  double get maxCandleSizeMultiplier =>
      (_m['maxCandleSizeMultiplier'] as num?)?.toDouble() ?? 2.5;
  double get minVolumeMultiplier =>
      (_m['minVolumeMultiplier'] as num?)?.toDouble() ?? 2.0;
  double get minAbsoluteVolume =>
      (_m['minAbsoluteVolume'] as num?)?.toDouble() ?? 5000;
  double get maxMovementMultiplier =>
      (_m['maxMovementMultiplier'] as num?)?.toDouble() ?? 2.0;
  double get maxGapUpPercent =>
      (_m['maxGapUpPercent'] as num?)?.toDouble() ?? 2.5;
  double get maxGapDownPercent =>
      (_m['maxGapDownPercent'] as num?)?.toDouble() ?? 1.0;
  int get scanIntervalMinutes =>
      (_m['scanIntervalMinutes'] as num?)?.toInt() ?? 5;
}

class _DominanceMetrics {
  final double bodyPercent;
  final double upperWickPercent;
  final double lowerWickPercent;
  final double sizeMultiplier;
  final double volumeMultiplier;

  _DominanceMetrics({
    required this.bodyPercent,
    required this.upperWickPercent,
    required this.lowerWickPercent,
    required this.sizeMultiplier,
    required this.volumeMultiplier,
  });
}

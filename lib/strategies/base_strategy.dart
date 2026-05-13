import 'package:candlesticks/candlesticks.dart';
import '../models/candle_stats_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/dhan_feed_service.dart';
import '../services/scrip_service.dart';

/// Parameter type for auto-generating config UI.
enum ParamType { integer, decimal, boolean, time }

/// Structured diagnostic output from a single [BaseStrategy.scan] call.
/// Lets the engine log "why nothing matched" without parsing log strings.
class ScanReport {
  /// Stocks present in todayCandles that had a non-empty candle list.
  final int stocksEvaluated;

  /// Candles whose time fell in the scan window — i.e. the only candles that
  /// were actually run through the dominance rules. Zero here means the scan
  /// window had no closed candles yet.
  final int candlesInWindow;

  /// Per-rule rejection counts (e.g. `{'R5-VolMult': 147, 'R6a-AbsVol': 31}`).
  final Map<String, int> rejectCounts;

  ScanReport({
    required this.stocksEvaluated,
    required this.candlesInWindow,
    required this.rejectCounts,
  });

  /// Top N rejection reasons as `key=count` pairs, highest first.
  List<String> topRejects([int n = 3]) {
    final entries = rejectCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(n).map((e) => '${e.key}=${e.value}').toList();
  }

  /// Total reject events (a single stock may be rejected multiple times across
  /// candles, so this can exceed stocksEvaluated).
  int get totalRejects =>
      rejectCounts.values.fold<int>(0, (sum, v) => sum + v);
}

/// Metadata for a single strategy parameter.
/// Drives automatic form generation in the config screen.
class StrategyParamDef {
  final String key;
  final String label;
  final String description;
  final ParamType type;
  final dynamic defaultValue;
  final dynamic min;
  final dynamic max;
  final String? unit; // '%', 'x', 'INR', 'min'
  final String group; // section header in config screen

  const StrategyParamDef({
    required this.key,
    required this.label,
    this.description = '',
    required this.type,
    required this.defaultValue,
    this.min,
    this.max,
    this.unit,
    required this.group,
  });
}

/// Abstract strategy interface. Every strategy must implement this contract.
/// The StrategyEngine calls these methods in order: prepare → scan → checkBreakout → checkExit.
abstract class BaseStrategy {
  /// Unique type identifier (stored in StrategyConfigModel.strategyType)
  String get type;

  /// Human-readable name shown in strategy list
  String get displayName;

  /// Short description
  String get description;

  /// Default parameter values for this strategy
  Map<String, dynamic> get defaultParams;

  /// Parameter definitions for auto-generating the config UI
  List<StrategyParamDef> get paramDefinitions;

  /// Phase 1: Pre-market preparation.
  /// Fetch historical data and compute stats for each stock.
  /// [onProgress] reports (completed, total) for UI progress bar.
  Future<Map<int, CandleStatsModel>> prepare({
    required List<int> securityIds,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Future<List<Candle>> Function(int securityId, String interval,
            {DateTime? date})
        fetchIntraday,
    required void Function(int completed, int total) onProgress,
  });

  /// Phase 2: Scan candles for entry signals (e.g. dominance candle detection).
  /// Called at each scan interval (e.g. every 5 min from 9:30-10:00).
  /// [todayCandles] maps securityId → list of today's 5-min candles (oldest first).
  /// [onScanReport] receives structured diagnostics (per-rule reject counts,
  /// candles examined) for downstream logging without parsing log strings.
  List<StrategySignalModel> scan({
    required String configId,
    required Map<int, CandleStatsModel> stats,
    required Map<int, List<Candle>> todayCandles,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Set<int> alreadySignalled,
    void Function(String message)? debugLog,
    void Function(ScanReport report)? onScanReport,
  });

  /// Phase 3: Check if a WebSocket tick triggers entry for any active signal.
  /// Returns a trade if breakout detected, null otherwise.
  StrategyTradeModel? checkBreakout({
    required FeedUpdate tick,
    required int securityId,
    required List<StrategySignalModel> activeSignals,
    required Map<String, dynamic> params,
    required int tradesPlacedToday,
    required bool isPaperTrade,
    required String configId,
  });

  /// Phase 4: Check if a tick hits SL or target for an open trade.
  /// Returns updated trade if exit triggered, null otherwise.
  StrategyTradeModel? checkExit({
    required FeedUpdate tick,
    required StrategyTradeModel trade,
  });

  /// Human-readable hint explaining what a reject key (e.g. 'R5-VolMult')
  /// usually means. Used by the engine's WHY ZERO diagnostic to give devs
  /// an actionable cause without grepping per-stock REJECT lines.
  /// Default implementation returns null — strategies override to ship hints.
  String? diagnosisHint(String rule) => null;
}

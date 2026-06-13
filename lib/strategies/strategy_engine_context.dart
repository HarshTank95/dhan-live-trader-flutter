import 'package:candlesticks/candlesticks.dart';
import '../models/backtest_result_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/scrip_service.dart';

/// Services a self-contained strategy ([BaseStrategy.hasCustomEngine] == true)
/// can use during the one-time backtest preparation phase (e.g. fetch daily
/// candles). The engine implements this and hands it to the strategy so the
/// engine itself stays strategy-agnostic.
abstract class BacktestPrepContext {
  Map<String, dynamic> get params;
  List<int> get securityIds;
  DateTime get fromDate;
  DateTime get toDate;
  String get accessToken;
  String get clientId;
  bool get isCancelled;
  void log(String message);

  /// Report prep progress to the UI (progress bar + status line). Long prep
  /// phases (e.g. daily-candle downloads) MUST call this — a silent phase
  /// looks like a frozen app.
  void progress(int completed, int total, String message);
}

/// Per-day backtest services. The strategy screens + simulates one trading day
/// and returns the [BacktestDayResult]; it never touches engine internals.
abstract class BacktestDayContext {
  String get dateStr;
  Map<String, dynamic> get params;
  List<int> get securityIds;
  ScripService get scripService;

  /// All cached intraday candles for [securityId] grouped by yyyy-MM-dd
  /// (each list oldest-first). Null if the stock has no data.
  Map<String, List<Candle>>? intradayByDate(int securityId);

  void log(String message);
  void runLogInfo(String tag, String message, [Map<String, dynamic>? data]);
  void runLogWarn(String tag, String message, [Map<String, dynamic>? data]);
}

/// Live/paper engine services exposed to a self-contained strategy. The engine
/// owns instrument loading, the run log, persistence and the background-service
/// plumbing; the strategy drives screening, entry and exit through this façade
/// and reports results back via [recordSignal] / [recordTrade].
abstract class LiveEngineContext {
  Map<String, dynamic> get params;
  List<int> get securityIds;
  ScripService get scripService;
  String get accessToken;
  String get clientId;
  String get configId;
  bool get isPaperTrading;
  bool get stopRequested;
  int get tradesPlacedToday;

  Future<List<Candle>> fetchIntraday(int securityId, String interval,
      {DateTime? date});
  Future<Map<int, double>> fetchLtpBatch(List<int> securityIds);
  Future<void> placeLiveOrder(StrategyTradeModel trade);

  void log(String message);
  void addKeyEvent(String event);
  void runLogInfo(String tag, String message, [Map<String, dynamic>? data]);
  void sendUpdate(String event, Map<String, dynamic> data);

  /// Report a screening hit (increments the run's signal counter).
  void recordSignal();

  /// Register a trade so the engine persists it and counts it toward the cap.
  void recordTrade(StrategyTradeModel trade);

  /// Report the final active-stock count (for the daily run summary).
  void recordActiveStocks(int count);
}

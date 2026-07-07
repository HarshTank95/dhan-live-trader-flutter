import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/backtest_result_model.dart';
import '../models/daily_run_summary_model.dart';
import '../models/paper_position_model.dart';
import '../models/paper_trade_model.dart';
import '../models/strategy_config_model.dart';
import '../models/strategy_trade_model.dart';
import '../models/watchlist_model.dart';
import 'scrip_service.dart';

class StorageService {
  static const _keyClientId = 'dhan_client_id';
  static const _keyAccessToken = 'dhan_access_token';
  static const _keyDarkMode = 'dark_mode';
  static const _keyWatchlists = 'all_watchlists';
  static const _keyActiveWatchlistId = 'active_watchlist_id';
  static const _keyStrategyConfigs = 'strategy_configs';
  static const _keyStrategyTrades = 'strategy_trades';
  static const _keyDailyRunHistory = 'daily_run_history';
  static const _keyBacktestResults = 'backtest_results';
  static const _keyActiveStrategyConfigId = 'active_strategy_config_id';
  static const _keyPaperPositions = 'paper_positions';
  static const _keyPaperTrades = 'paper_trades';
  static const _keyPaperBalance = 'paper_balance';
  static const _keyPaperInitialCapital = 'paper_initial_capital';
  static const _keyTradingMode = 'trading_mode';
  static const _keyLogRetentionDays = 'log_retention_days';

  // ── Per-run log retention ────────────────────────────────────────────
  /// Default: 14 days. UI exposes 7 / 14 / 30 presets but any int is accepted.
  static Future<int> getLogRetentionDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyLogRetentionDays) ?? 14;
  }

  static Future<void> setLogRetentionDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLogRetentionDays, days);
  }

  // ── Active Strategy Tracking ───────────────────────────────────────
  static Future<void> setActiveStrategy(String? configId) async {
    final prefs = await SharedPreferences.getInstance();
    if (configId == null) {
      await prefs.remove(_keyActiveStrategyConfigId);
    } else {
      await prefs.setString(_keyActiveStrategyConfigId, configId);
    }
  }

  static Future<String?> getActiveStrategy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActiveStrategyConfigId);
  }

  // ── Credentials ──────────────────────────────────────────────────────
  static Future<void> saveCredentials({
    required String clientId,
    required String accessToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyClientId, clientId);
    await prefs.setString(_keyAccessToken, accessToken);
  }

  static Future<({String clientId, String accessToken})?> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString(_keyClientId);
    final accessToken = prefs.getString(_keyAccessToken);
    if (clientId == null || accessToken == null) return null;
    return (clientId: clientId, accessToken: accessToken);
  }

  static Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyClientId);
    await prefs.remove(_keyAccessToken);
  }

  // ── Theme ─────────────────────────────────────────────────────────────
  static Future<void> saveTheme(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDarkMode, isDark);
  }

  static Future<bool> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDarkMode) ?? false;
  }

  // ── Watchlists ────────────────────────────────────────────────────────
  static Future<void> saveAllWatchlists(List<WatchlistModel> watchlists) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(watchlists.map((w) => w.toJson()).toList());
    await prefs.setString(_keyWatchlists, json);
  }

  static Future<List<WatchlistModel>> loadAllWatchlists() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyWatchlists);

    if (json == null) {
      // First launch — create default watchlist
      return [
        WatchlistModel(
          name: 'My Watchlist',
          stockIds: ScripService.defaultWatchlist,
        )
      ];
    }

    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => WatchlistModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [
        WatchlistModel(
          name: 'My Watchlist',
          stockIds: ScripService.defaultWatchlist,
        )
      ];
    }
  }

  static Future<void> saveActiveWatchlistId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyActiveWatchlistId, id);
  }

  static Future<String?> loadActiveWatchlistId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActiveWatchlistId);
  }

  // ── Strategy Configs ────────────────────────────────────────────────────
  static Future<void> saveStrategyConfigs(
      List<StrategyConfigModel> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(configs.map((c) => c.toJson()).toList());
    await prefs.setString(_keyStrategyConfigs, json);
  }

  static Future<List<StrategyConfigModel>> loadStrategyConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyStrategyConfigs);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => StrategyConfigModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Strategy Trades ─────────────────────────────────────────────────────
  static Future<void> saveStrategyTrades(
      List<StrategyTradeModel> trades) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(trades.map((t) => t.toJson()).toList());
    await prefs.setString(_keyStrategyTrades, json);
  }

  static Future<List<StrategyTradeModel>> loadStrategyTrades() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyStrategyTrades);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => StrategyTradeModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Daily Run History ───────────────────────────────────────────────────
  static Future<void> saveDailyRunSummary(DailyRunSummaryModel summary) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await loadDailyRunHistory();

    // Replace existing entry for same date + configId, or add new
    history.removeWhere(
        (h) => h.date == summary.date && h.configId == summary.configId);
    history.insert(0, summary); // newest first

    // Keep max 30 days of history
    if (history.length > 30) {
      history.removeRange(30, history.length);
    }

    final json = jsonEncode(history.map((h) => h.toJson()).toList());
    await prefs.setString(_keyDailyRunHistory, json);
  }

  static Future<List<DailyRunSummaryModel>> loadDailyRunHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyDailyRunHistory);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) =>
              DailyRunSummaryModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> deleteDailyRun(String date, String configId) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await loadDailyRunHistory();
    history
        .removeWhere((h) => h.date == date && h.configId == configId);
    final json = jsonEncode(history.map((h) => h.toJson()).toList());
    await prefs.setString(_keyDailyRunHistory, json);
  }

  static Future<void> clearAllDailyRunHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyDailyRunHistory);
  }

  // ── Backtest Results ──────────────────────────────────────────────────
  // One JSON file per result under {appDocs}/backtest_results/. Results used
  // to live as ONE giant string in SharedPreferences — a multi-year run holds
  // thousands of trades, so a few runs made the prefs blob tens of MB, and
  // Android rewrites the WHOLE prefs file on EVERY write (progress updates,
  // activity flushes...). That made the second backtest of a session jank/ANR.
  // Files keep prefs tiny; the public API is unchanged.

  static Future<Directory> _backtestResultsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/backtest_results');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Sanitize an id for use as a file name (ids are UUIDs today; be safe).
  static String _resultFileName(String id) =>
      '${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  /// One-time migration: move any results still in the legacy prefs blob to
  /// files, then drop the prefs key (frees the multi-MB string for good).
  static Future<void> _migrateLegacyBacktestResults() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyBacktestResults);
    if (json == null) return;
    try {
      final dir = await _backtestResultsDir();
      final list = jsonDecode(json) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final id = (m['id'] ?? '') as String;
        if (id.isEmpty) continue;
        final f = File('${dir.path}/${_resultFileName(id)}');
        if (!await f.exists()) await f.writeAsString(jsonEncode(m));
      }
    } catch (_) {
      // Corrupt legacy blob — nothing to salvage; fall through to remove it.
    }
    await prefs.remove(_keyBacktestResults);
  }

  static Future<void> saveBacktestResult(BacktestResultModel result) async {
    await _migrateLegacyBacktestResults();
    final dir = await _backtestResultsDir();
    await File('${dir.path}/${_resultFileName(result.id)}')
        .writeAsString(jsonEncode(result.toJson()));

    // Keep max 20 results — drop the oldest files beyond that.
    final files = await _listResultFiles(dir);
    if (files.length > 20) {
      for (final f in files.sublist(20)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Result files, newest first (by modification time).
  static Future<List<File>> _listResultFiles(Directory dir) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) files.add(e);
    }
    files.sort((a, b) =>
        b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  static Future<List<BacktestResultModel>> loadBacktestResults() async {
    await _migrateLegacyBacktestResults();
    final dir = await _backtestResultsDir();
    final results = <BacktestResultModel>[];
    for (final f in await _listResultFiles(dir)) {
      try {
        results.add(BacktestResultModel.fromJson(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Skip unreadable/corrupt file rather than failing the whole list.
      }
    }
    results.sort((a, b) => b.runAt.compareTo(a.runAt)); // newest first
    return results;
  }

  static Future<void> deleteBacktestResult(String id) async {
    await _migrateLegacyBacktestResults();
    final dir = await _backtestResultsDir();
    final f = File('${dir.path}/${_resultFileName(id)}');
    if (await f.exists()) await f.delete();
  }

  static Future<void> clearAllBacktestResults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyBacktestResults); // legacy blob, if any
    final dir = await _backtestResultsDir();
    for (final f in await _listResultFiles(dir)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  // ── Trading Mode (Paper / Live) ─────────────────────────────────────
  static Future<void> saveTradingMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTradingMode, mode);
  }

  static Future<String> loadTradingMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyTradingMode) ?? 'paper';
  }

  // ── Paper Trading ───────────────────────────────────────────────────
  static Future<void> savePaperPositions(
      List<PaperPositionModel> positions) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(positions.map((p) => p.toJson()).toList());
    await prefs.setString(_keyPaperPositions, json);
  }

  static Future<List<PaperPositionModel>> loadPaperPositions() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyPaperPositions);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => PaperPositionModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePaperTrades(List<PaperTradeModel> trades) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(trades.map((t) => t.toJson()).toList());
    await prefs.setString(_keyPaperTrades, json);
  }

  static Future<List<PaperTradeModel>> loadPaperTrades() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyPaperTrades);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => PaperTradeModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePaperBalance(
      double available, double initial) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyPaperBalance, available);
    await prefs.setDouble(_keyPaperInitialCapital, initial);
  }

  static Future<({double available, double initial})?> loadPaperBalance() async {
    final prefs = await SharedPreferences.getInstance();
    final available = prefs.getDouble(_keyPaperBalance);
    final initial = prefs.getDouble(_keyPaperInitialCapital);
    if (available == null) return null;
    return (available: available, initial: initial ?? 1000000);
  }

  static Future<void> clearPaperData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPaperPositions);
    await prefs.remove(_keyPaperTrades);
    await prefs.remove(_keyPaperBalance);
    await prefs.remove(_keyPaperInitialCapital);
  }
}

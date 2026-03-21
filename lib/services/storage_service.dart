import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/daily_run_summary_model.dart';
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
}

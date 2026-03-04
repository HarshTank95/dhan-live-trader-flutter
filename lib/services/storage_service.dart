import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/watchlist_model.dart';
import 'scrip_service.dart';

class StorageService {
  static const _keyClientId = 'dhan_client_id';
  static const _keyAccessToken = 'dhan_access_token';
  static const _keyDarkMode = 'dark_mode';
  static const _keyWatchlists = 'all_watchlists';
  static const _keyActiveWatchlistId = 'active_watchlist_id';

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
}

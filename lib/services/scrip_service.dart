import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/nifty500_stocks.dart';

class ScripInfo {
  final String symbol;
  final String name;
  final int securityId;

  const ScripInfo({
    required this.symbol,
    required this.name,
    required this.securityId,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'name': name,
        'securityId': securityId,
      };

  factory ScripInfo.fromJson(Map<String, dynamic> json) => ScripInfo(
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        securityId: json['securityId'] as int,
      );
}

class ScripService {
  // Singleton instance — scrips are loaded once and shared across the app.
  static final ScripService _instance = ScripService._internal();
  factory ScripService() => _instance;
  ScripService._internal();

  // Authenticated endpoint — returns NSE_EQ only (much smaller than full CSV)
  static const _nseEqUrl = 'https://api.dhan.co/v2/instrument/NSE_EQ';
  // Public fallback — full master with all segments
  static const _fallbackUrl =
      'https://images.dhan.co/api-data/api-scrip-master.csv';
  static const _cacheKey = 'scrip_cache_date';
  static const _cacheFile = 'scrips_cache.json';

  // Default watchlist security IDs
  static const List<int> defaultWatchlist = [2885, 11536, 1594, 1333, 1660];

  List<ScripInfo> _scrips = [];
  bool get isLoaded => _scrips.isNotEmpty;

  // ── Load scrips (cache-first, download if stale) ────────────────────
  //
  // Passes credentials so we can use the authenticated NSE_EQ endpoint
  // (returns only ~2,000 equity rows vs the full 50,000-row master CSV).
  Future<void> loadScrips({String? clientId, String? accessToken}) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedDate = prefs.getString(_cacheKey) ?? '';
    final today = _today();

    if (cachedDate == today) {
      final cached = await _loadFromFile();
      if (cached != null && cached.isNotEmpty) {
        _scrips = cached;
        return;
      }
    }

    // Try authenticated NSE_EQ-only endpoint first (fastest)
    List<ScripInfo> downloaded = [];
    if (clientId != null && accessToken != null) {
      downloaded = await _downloadNseEq(clientId, accessToken);
    }

    // Fall back to public full-master CSV if auth endpoint failed
    if (downloaded.isEmpty) {
      downloaded = await _downloadAndParse();
    }

    if (downloaded.isNotEmpty) {
      _scrips = downloaded;
      await _saveToFile(downloaded);
      await prefs.setString(_cacheKey, today);
    } else if (_scrips.isEmpty) {
      // Last resort: use stale cache
      final cached = await _loadFromFile();
      if (cached != null) _scrips = cached;
    }
  }

  // ── Nifty 500 stock universe (matches C# GetNseEquities) ────────────
  /// Returns security IDs of all loaded NSE EQ scrips that are in the
  /// Nifty 500 list. Mirrors C#: InstrumentService.GetNseEquities(limit).
  List<int> getNifty500SecurityIds({int limit = 500}) {
    return _scrips
        .where((s) => Nifty500Stocks.isNifty500(s.symbol))
        .take(limit)
        .map((s) => s.securityId)
        .toList();
  }

  /// Returns ScripInfo list for Nifty 500 stocks.
  List<ScripInfo> getNifty500Scrips({int limit = 500}) {
    return _scrips
        .where((s) => Nifty500Stocks.isNifty500(s.symbol))
        .take(limit)
        .toList();
  }

  // ── Search from loaded scrips ────────────────────────────────────────
  List<ScripInfo> search(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return _scrips.take(50).toList();
    return _scrips
        .where((s) =>
            s.symbol.toLowerCase().contains(q) ||
            s.name.toLowerCase().contains(q))
        .take(50)
        .toList();
  }

  // ── Resolve security IDs → ScripInfo ────────────────────────────────
  ScripInfo? findById(int securityId) {
    try {
      return _scrips.firstWhere((s) => s.securityId == securityId);
    } catch (_) {
      return null;
    }
  }

  // ── Download NSE_EQ only via authenticated API (primary) ─────────────
  Future<List<ScripInfo>> _downloadNseEq(
      String clientId, String accessToken) async {
    try {
      final response = await http.get(
        Uri.parse(_nseEqUrl),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Accept': 'text/csv',
        },
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      return _parseCsv(response.body); // same CSV format, already NSE_EQ
    } catch (_) {
      return [];
    }
  }

  // ── Download full master CSV (fallback, no auth needed) ──────────────
  Future<List<ScripInfo>> _downloadAndParse() async {
    try {
      final response = await http
          .get(Uri.parse(_fallbackUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return [];
      return _parseCsv(response.body);
    } catch (_) {
      return [];
    }
  }

  List<ScripInfo> _parseCsv(String csv) {
    final lines = csv.split('\n');
    final scrips = <ScripInfo>[];

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final cols = line.split(',');
      if (cols.length < 16) continue;

      // Only NSE equity stocks with EQ series
      if (cols[0].trim() != 'NSE') continue;
      if (cols[1].trim() != 'E') continue;
      if (cols[3].trim() != 'EQUITY') continue;
      if (cols[14].trim() != 'EQ') continue;

      final securityId = int.tryParse(cols[2].trim());
      if (securityId == null) continue;

      final symbol = cols[5].trim();
      final name = cols[15].trim();
      if (symbol.isEmpty) continue;

      scrips.add(ScripInfo(symbol: symbol, name: name, securityId: securityId));
    }

    return scrips;
  }

  // ── File cache ───────────────────────────────────────────────────────
  Future<File> _getCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_cacheFile');
  }

  Future<void> _saveToFile(List<ScripInfo> scrips) async {
    try {
      final file = await _getCacheFile();
      await file.writeAsString(
          jsonEncode(scrips.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }

  Future<List<ScripInfo>?> _loadFromFile() async {
    try {
      final file = await _getCacheFile();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final list = jsonDecode(content) as List<dynamic>;
      return list.map((e) => ScripInfo.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  String _today() => DateTime.now().toIso8601String().substring(0, 10);
}

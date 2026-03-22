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

  // ── Nifty index constituents (fetched from official NSE source) ─────

  // Cached index symbols fetched from niftyindices.com
  Set<String> _nifty50Symbols = {};
  Set<String> _nifty200Symbols = {};
  Set<String> _nifty500Symbols = {};
  bool _indexSymbolsLoaded = false;

  static const _indexBaseUrl = 'https://www.niftyindices.com/IndexConstituent';
  static const _indexCacheKey = 'nifty_index_cache_date';

  /// Fetch Nifty index constituent lists from official NSE source.
  /// Caches for the day. Falls back to hardcoded list if fetch fails.
  Future<void> loadIndexConstituents() async {
    if (_indexSymbolsLoaded) return;

    final prefs = await SharedPreferences.getInstance();
    final cachedDate = prefs.getString(_indexCacheKey) ?? '';
    final today = _today();

    // Try loading from cache first
    if (cachedDate == today) {
      final cached50 = prefs.getStringList('nifty50_symbols');
      final cached200 = prefs.getStringList('nifty200_symbols');
      final cached500 = prefs.getStringList('nifty500_symbols');
      if (cached500 != null && cached500.isNotEmpty) {
        _nifty50Symbols = cached50?.toSet() ?? {};
        _nifty200Symbols = cached200?.toSet() ?? {};
        _nifty500Symbols = cached500.toSet();
        _indexSymbolsLoaded = true;
        return;
      }
    }

    // Fetch from niftyindices.com
    try {
      final results = await Future.wait([
        _fetchIndexCsv('ind_nifty50list.csv'),
        _fetchIndexCsv('ind_nifty200list.csv'),
        _fetchIndexCsv('ind_nifty500list.csv'),
      ]);

      if (results[2].isNotEmpty) {
        _nifty50Symbols = results[0];
        _nifty200Symbols = results[1];
        _nifty500Symbols = results[2];
        _indexSymbolsLoaded = true;

        // Cache for the day
        await prefs.setStringList('nifty50_symbols', _nifty50Symbols.toList());
        await prefs.setStringList('nifty200_symbols', _nifty200Symbols.toList());
        await prefs.setStringList('nifty500_symbols', _nifty500Symbols.toList());
        await prefs.setString(_indexCacheKey, today);

        return;
      }
    } catch (_) {}

    // Fallback to hardcoded list
    _nifty500Symbols = Nifty500Stocks.symbols;
    _indexSymbolsLoaded = true;
  }

  // NSE symbol → Dhan trading symbol mapping for known mismatches
  static const _symbolAliases = <String, String>{
    // Add mappings here as: 'NSE_SYMBOL': 'DHAN_SYMBOL'
    // e.g. 'RELINFRA': 'RELIANCEINFRA',
  };

  Future<Set<String>> _fetchIndexCsv(String fileName) async {
    try {
      final response = await http.get(
        Uri.parse('$_indexBaseUrl/$fileName'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/csv,text/plain,*/*',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return {};

      final symbols = <String>{};
      final lines = response.body.split('\n');
      for (int i = 1; i < lines.length; i++) { // skip header
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        // CSV columns: Company Name, Industry, Symbol, Series, ISIN
        final parts = line.split(',');
        if (parts.length >= 3) {
          final symbol = parts[2].trim().replaceAll('"', '');
          if (symbol.isNotEmpty && symbol != 'Symbol') {
            symbols.add(symbol.toUpperCase());
          }
        }
      }
      return symbols;
    } catch (_) {
      return {};
    }
  }

  /// Returns security IDs for a given index universe.
  /// Uses dynamically fetched constituents; falls back to hardcoded list.
  List<int> getSecurityIdsForUniverse(String universe) {
    Set<String> indexSymbols;
    switch (universe) {
      case 'Nifty 50':
        indexSymbols = _nifty50Symbols.isNotEmpty ? _nifty50Symbols : Nifty500Stocks.symbols;
        break;
      case 'Nifty 200':
        indexSymbols = _nifty200Symbols.isNotEmpty ? _nifty200Symbols : Nifty500Stocks.symbols;
        break;
      default:
        indexSymbols = _nifty500Symbols.isNotEmpty ? _nifty500Symbols : Nifty500Stocks.symbols;
    }

    // Build expanded set: original NSE symbols + Dhan aliases
    final expandedSymbols = <String>{...indexSymbols};
    for (final entry in _symbolAliases.entries) {
      if (indexSymbols.contains(entry.key)) {
        expandedSymbols.add(entry.value);
      }
    }

    final matched = _scrips
        .where((s) => expandedSymbols.contains(s.symbol.toUpperCase()))
        .toList();

    // For Nifty 50 with hardcoded fallback, take first 50
    if (universe == 'Nifty 50' && _nifty50Symbols.isEmpty) {
      return matched.take(50).map((s) => s.securityId).toList();
    }
    if (universe == 'Nifty 200' && _nifty200Symbols.isEmpty) {
      return matched.take(200).map((s) => s.securityId).toList();
    }

    return matched.map((s) => s.securityId).toList();
  }

  /// Legacy method — kept for backward compatibility.
  List<int> getNifty500SecurityIds({int limit = 500}) {
    return getSecurityIdsForUniverse(
      limit <= 50 ? 'Nifty 50' : limit <= 200 ? 'Nifty 200' : 'Nifty 500',
    );
  }

  /// Returns ScripInfo list for Nifty 500 stocks.
  List<ScripInfo> getNifty500Scrips({int limit = 500}) {
    final universe = limit <= 50 ? 'Nifty 50' : limit <= 200 ? 'Nifty 200' : 'Nifty 500';
    Set<String> indexSymbols;
    switch (universe) {
      case 'Nifty 50':
        indexSymbols = _nifty50Symbols.isNotEmpty ? _nifty50Symbols : Nifty500Stocks.symbols;
        break;
      case 'Nifty 200':
        indexSymbols = _nifty200Symbols.isNotEmpty ? _nifty200Symbols : Nifty500Stocks.symbols;
        break;
      default:
        indexSymbols = _nifty500Symbols.isNotEmpty ? _nifty500Symbols : Nifty500Stocks.symbols;
    }
    final expandedSymbols = <String>{...indexSymbols};
    for (final entry in _symbolAliases.entries) {
      if (indexSymbols.contains(entry.key)) {
        expandedSymbols.add(entry.value);
      }
    }
    return _scrips
        .where((s) => expandedSymbols.contains(s.symbol.toUpperCase()))
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

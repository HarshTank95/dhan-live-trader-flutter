import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/nifty500_stocks.dart';
import 'app_logger.dart';

// ── Segment enum ─────────────────────────────────────────────────────────────

enum ScripSegment { equity, futures, options }

// ── ScripInfo model ──────────────────────────────────────────────────────────

class ScripInfo {
  final String symbol;
  final String name;
  final int securityId;
  final ScripSegment segment;
  final String exchangeSegment; // 'NSE_EQ' or 'NSE_FNO'
  final String? instrumentType; // EQUITY, FUTIDX, FUTSTK, OPTIDX, OPTSTK
  final DateTime? expiryDate;
  final double? strikePrice;
  final String? optionType; // CE or PE
  final double? lotSize;
  final String? underlyingSymbol; // e.g. "TATAMOTORS" for F&O instruments

  const ScripInfo({
    required this.symbol,
    required this.name,
    required this.securityId,
    this.segment = ScripSegment.equity,
    this.exchangeSegment = 'NSE_EQ',
    this.instrumentType,
    this.expiryDate,
    this.strikePrice,
    this.optionType,
    this.lotSize,
    this.underlyingSymbol,
  });

  /// Display name for search results
  String get displayName {
    switch (segment) {
      case ScripSegment.futures:
        final exp = expiryDate != null ? _fmtExpiry(expiryDate!) : '';
        return '$symbol FUT $exp';
      case ScripSegment.options:
        final exp = expiryDate != null ? _fmtExpiry(expiryDate!) : '';
        final strike = strikePrice?.toStringAsFixed(strikePrice! == strikePrice!.roundToDouble() ? 0 : 2) ?? '';
        return '$symbol $strike ${optionType ?? ''} $exp';
      default:
        return symbol;
    }
  }

  bool get isExpired =>
      expiryDate != null && expiryDate!.isBefore(DateTime.now());

  /// Underlying symbol (e.g. "TATAMOTORS" for any TATAMOTORS F&O instrument)
  String get underlying {
    if (underlyingSymbol != null) return underlyingSymbol!;
    // Fallback: strip after first dash (e.g. "RELIANCE-Mar2026-FUT" → "RELIANCE")
    final dash = symbol.indexOf('-');
    return dash > 0 ? symbol.substring(0, dash) : symbol;
  }

  static String _fmtExpiry(DateTime d) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'name': name,
        'securityId': securityId,
        'segment': segment.index,
        'exchangeSegment': exchangeSegment,
        if (instrumentType != null) 'instrumentType': instrumentType,
        if (expiryDate != null) 'expiryDate': expiryDate!.toIso8601String(),
        if (strikePrice != null) 'strikePrice': strikePrice,
        if (optionType != null) 'optionType': optionType,
        if (lotSize != null) 'lotSize': lotSize,
        if (underlyingSymbol != null) 'underlyingSymbol': underlyingSymbol,
      };

  factory ScripInfo.fromJson(Map<String, dynamic> json) => ScripInfo(
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        securityId: json['securityId'] as int,
        segment: ScripSegment.values.elementAtOrNull(
                json['segment'] as int? ?? 0) ??
            ScripSegment.equity,
        exchangeSegment: json['exchangeSegment'] as String? ?? 'NSE_EQ',
        instrumentType: json['instrumentType'] as String?,
        expiryDate: json['expiryDate'] != null
            ? DateTime.tryParse(json['expiryDate'] as String)
            : null,
        strikePrice: (json['strikePrice'] as num?)?.toDouble(),
        optionType: json['optionType'] as String?,
        lotSize: (json['lotSize'] as num?)?.toDouble(),
        underlyingSymbol: json['underlyingSymbol'] as String?,
      );
}

// ── ScripService ─────────────────────────────────────────────────────────────

class ScripService {
  // Singleton instance — scrips are loaded once and shared across the app.
  static final ScripService _instance = ScripService._internal();
  factory ScripService() => _instance;
  ScripService._internal();

  // Authenticated endpoint — returns NSE_EQ only (much smaller than full CSV)
  static const _nseEqUrl = 'https://api.dhan.co/v2/instrument/NSE_EQ';
  static const _nseFnoUrl = 'https://api.dhan.co/v2/instrument/NSE_FNO';
  // Public fallback — full master with all segments
  static const _fallbackUrl =
      'https://images.dhan.co/api-data/api-scrip-master.csv';
  static const _cacheKey = 'scrip_cache_date';
  static const _cacheFile = 'scrips_cache.json';
  static const _fnoCacheKey = 'scrip_fno_cache_date_v2'; // v2: includes underlyingSymbol
  static const _fnoCacheFile = 'scrips_fno_cache_v2.json';

  // Default watchlist security IDs
  static const List<int> defaultWatchlist = [2885, 11536, 1594, 1333, 1660];

  List<ScripInfo> _scrips = []; // equity only
  List<ScripInfo> _fnoScrips = []; // futures + options
  bool get isLoaded => _scrips.isNotEmpty;
  bool get isFnoLoaded => _fnoScrips.isNotEmpty;

  // ── Load equity scrips (cache-first, download if stale) ────────────────
  Future<void> loadScrips({String? clientId, String? accessToken}) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedDate = prefs.getString(_cacheKey) ?? '';
    final today = _today();

    if (cachedDate == today) {
      final cached = await _loadFromFile(_cacheFile);
      if (cached != null && cached.isNotEmpty) {
        _scrips = cached;
        await _loadFnoScrips(clientId: clientId, accessToken: accessToken);
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
      downloaded = await _downloadAndParseEquity();
    }

    if (downloaded.isNotEmpty) {
      _scrips = downloaded;
      await _saveToFile(downloaded, _cacheFile);
      await prefs.setString(_cacheKey, today);
    } else if (_scrips.isEmpty) {
      // Last resort: use stale cache
      final cached = await _loadFromFile(_cacheFile);
      if (cached != null) _scrips = cached;
    }

    // Loud diagnostics: an empty scrip master cripples the whole app (watchlist
    // shows raw IDs, search finds nothing, strategies have no universe). This
    // failed silently once after a reinstall wiped the cache — never again.
    if (_scrips.isEmpty) {
      AppLogger.error('Scrip',
          'Scrip master EMPTY after load: auth endpoint + public CSV + cache all failed. Watchlist/search/universe will not work. Check token validity and network, then restart.');
    } else {
      AppLogger.info('Scrip', 'Scrip master loaded: ${_scrips.length} equities');
    }

    // Load F&O
    await _loadFnoScrips(clientId: clientId, accessToken: accessToken);
  }

  // ── Load F&O scrips ────────────────────────────────────────────────────
  Future<void> _loadFnoScrips({String? clientId, String? accessToken}) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedDate = prefs.getString(_fnoCacheKey) ?? '';
    final today = _today();

    if (cachedDate == today) {
      final cached = await _loadFromFile(_fnoCacheFile);
      if (cached != null && cached.isNotEmpty) {
        _fnoScrips = cached;
        return;
      }
    }

    // Try authenticated NSE_FNO endpoint
    List<ScripInfo> downloaded = [];
    if (clientId != null && accessToken != null) {
      downloaded = await _downloadNseFno(clientId, accessToken);
    }

    // Fallback: parse full master CSV for F&O
    if (downloaded.isEmpty) {
      downloaded = await _downloadAndParseFno();
    }

    if (downloaded.isNotEmpty) {
      _fnoScrips = downloaded;
      await _saveToFile(downloaded, _fnoCacheFile);
      await prefs.setString(_fnoCacheKey, today);
    } else if (_fnoScrips.isEmpty) {
      final cached = await _loadFromFile(_fnoCacheFile);
      if (cached != null) _fnoScrips = cached;
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

    final expandedSymbols = <String>{...indexSymbols};
    for (final entry in _symbolAliases.entries) {
      if (indexSymbols.contains(entry.key)) {
        expandedSymbols.add(entry.value);
      }
    }

    final matched = _scrips
        .where((s) => expandedSymbols.contains(s.symbol.toUpperCase()))
        .toList();

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

  // ── Search ─────────────────────────────────────────────────────────────

  /// Search equity only (backward compatible)
  List<ScripInfo> search(String query) {
    return searchWithFilter(query, segment: ScripSegment.equity);
  }

  /// Search with optional segment filter
  List<ScripInfo> searchWithFilter(String query, {ScripSegment? segment}) {
    final q = query.toLowerCase().trim();

    List<ScripInfo> source;
    switch (segment) {
      case ScripSegment.equity:
        source = _scrips;
        break;
      case ScripSegment.futures:
        source = _fnoScrips
            .where((s) => s.segment == ScripSegment.futures && !s.isExpired)
            .toList();
        break;
      case ScripSegment.options:
        // Only show current + next month options to keep results manageable
        final now = DateTime.now();
        final cutoff = DateTime(now.year, now.month + 2, 1);
        source = _fnoScrips
            .where((s) =>
                s.segment == ScripSegment.options &&
                !s.isExpired &&
                (s.expiryDate == null || s.expiryDate!.isBefore(cutoff)))
            .toList();
        break;
      case null:
        // All segments: equity + non-expired F&O
        source = [
          ..._scrips,
          ..._fnoScrips.where((s) => !s.isExpired),
        ];
        break;
    }

    if (q.isEmpty) return source.take(50).toList();

    // Build underlying→equity name lookup for F&O matching
    // e.g., "TATAMOTORS" → "TATA MOTORS LTD" so searching "tata motors"
    // also finds TATAMOTORS futures/options
    final equityNameMap = <String, String>{};
    if (segment != ScripSegment.equity) {
      for (final s in _scrips) {
        equityNameMap[s.symbol.toUpperCase()] = s.name.toLowerCase();
      }
    }

    bool matches(ScripInfo s) {
      if (s.symbol.toLowerCase().contains(q)) return true;
      if (s.name.toLowerCase().contains(q)) return true;
      if (s.displayName.toLowerCase().contains(q)) return true;
      // For F&O: also match by underlying equity stock name
      if (s.segment != ScripSegment.equity) {
        final equityName = equityNameMap[s.underlying.toUpperCase()];
        if (equityName != null && equityName.contains(q)) return true;
      }
      return false;
    }

    // When showing all segments, collect per-segment to ensure each is represented
    if (segment == null) {
      final eqResults = <ScripInfo>[];
      final futResults = <ScripInfo>[];
      final optResults = <ScripInfo>[];
      for (final s in source) {
        if (!matches(s)) continue;
        switch (s.segment) {
          case ScripSegment.equity:
            if (eqResults.length < 20) eqResults.add(s);
            break;
          case ScripSegment.futures:
            if (futResults.length < 10) futResults.add(s);
            break;
          case ScripSegment.options:
            if (optResults.length < 20) optResults.add(s);
            break;
        }
        if (eqResults.length + futResults.length + optResults.length >= 50) break;
      }
      return [...eqResults, ...futResults, ...optResults];
    }

    return source.where(matches).take(50).toList();
  }

  // ── Resolve security IDs → ScripInfo ────────────────────────────────
  ScripInfo? findById(int securityId) {
    // Try equity first (most common)
    for (final s in _scrips) {
      if (s.securityId == securityId) return s;
    }
    // Then F&O
    for (final s in _fnoScrips) {
      if (s.securityId == securityId) return s;
    }
    return null;
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
      if (response.statusCode != 200) {
        AppLogger.error('Scrip',
            'NSE_EQ instrument endpoint HTTP ${response.statusCode}: ${response.body.length > 150 ? response.body.substring(0, 150) : response.body}');
        return [];
      }
      return _parseEquityCsv(response.body);
    } catch (e) {
      AppLogger.error('Scrip', 'NSE_EQ instrument fetch failed: $e');
      return [];
    }
  }

  // ── Download NSE_FNO via authenticated API ────────────────────────────
  Future<List<ScripInfo>> _downloadNseFno(
      String clientId, String accessToken) async {
    try {
      final response = await http.get(
        Uri.parse(_nseFnoUrl),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Accept': 'text/csv',
        },
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        AppLogger.error('Scrip',
            'NSE_FNO instrument endpoint HTTP ${response.statusCode}');
        return [];
      }
      return _parseFnoCsv(response.body);
    } catch (e) {
      AppLogger.error('Scrip', 'NSE_FNO instrument fetch failed: $e');
      return [];
    }
  }

  // ── Download full master CSV (fallback, no auth needed) ──────────────
  Future<List<ScripInfo>> _downloadAndParseEquity() async {
    try {
      final response = await http
          .get(Uri.parse(_fallbackUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        AppLogger.error(
            'Scrip', 'Public scrip-master CSV HTTP ${response.statusCode}');
        return [];
      }
      return _parseEquityCsv(response.body);
    } catch (e) {
      AppLogger.error('Scrip', 'Public scrip-master CSV fetch failed: $e');
      return [];
    }
  }

  Future<List<ScripInfo>> _downloadAndParseFno() async {
    try {
      final response = await http
          .get(Uri.parse(_fallbackUrl))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) return [];
      return _parseFnoCsv(response.body);
    } catch (_) {
      return [];
    }
  }

  // ── CSV parsers ────────────────────────────────────────────────────────

  /// Parse equity instruments from Dhan CSV
  /// Columns: 0=Exchange, 1=Segment(E), 2=SecurityId, 3=InstrumentName,
  ///          5=TradingSymbol, 14=Series, 15=SymbolName
  List<ScripInfo> _parseEquityCsv(String csv) {
    final lines = csv.split('\n');
    final scrips = <ScripInfo>[];

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final cols = line.split(',');
      if (cols.length < 16) continue;

      if (cols[0].trim() != 'NSE') continue;
      if (cols[1].trim() != 'E') continue;
      if (cols[3].trim() != 'EQUITY') continue;
      if (cols[14].trim() != 'EQ') continue;

      final securityId = int.tryParse(cols[2].trim());
      if (securityId == null) continue;

      final symbol = cols[5].trim();
      final name = cols[15].trim();
      if (symbol.isEmpty) continue;

      scrips.add(ScripInfo(
        symbol: symbol,
        name: name,
        securityId: securityId,
        segment: ScripSegment.equity,
        exchangeSegment: 'NSE_EQ',
        instrumentType: 'EQUITY',
      ));
    }

    return scrips;
  }

  /// Parse F&O instruments from Dhan CSV
  /// Columns: 0=Exchange, 1=Segment(D), 2=SecurityId, 3=InstrumentName,
  ///          5=TradingSymbol, 6=LotSize, 7=CustomSymbol,
  ///          8=ExpiryDate, 9=StrikePrice, 10=OptionType,
  ///          13=ExchInstrumentType, 15=SymbolName
  List<ScripInfo> _parseFnoCsv(String csv) {
    final lines = csv.split('\n');
    final scrips = <ScripInfo>[];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final cols = line.split(',');
      if (cols.length < 16) continue;

      // Only NSE derivatives
      if (cols[0].trim() != 'NSE') continue;
      if (cols[1].trim() != 'D') continue;

      final instrType = cols[3].trim();
      // Only futures and options (skip test instruments)
      if (!{'FUTIDX', 'FUTSTK', 'OPTIDX', 'OPTSTK'}.contains(instrType)) continue;

      final securityId = int.tryParse(cols[2].trim());
      if (securityId == null) continue;

      final symbol = cols[5].trim();
      if (symbol.isEmpty) continue;

      // Skip test instruments
      if (symbol.contains('NSETEST')) continue;

      // Parse expiry date
      final expiryStr = cols[8].trim();
      DateTime? expiryDate;
      if (expiryStr.isNotEmpty) {
        expiryDate = DateTime.tryParse(expiryStr);
      }

      // Skip expired instruments
      if (expiryDate != null && expiryDate.isBefore(today)) continue;

      // Parse strike price
      final strikeStr = cols[9].trim();
      double? strikePrice;
      if (strikeStr.isNotEmpty) {
        strikePrice = double.tryParse(strikeStr);
        if (strikePrice != null && strikePrice <= 0) strikePrice = null;
      }

      // Parse option type
      String? optionType;
      final optTypeStr = cols[10].trim();
      if (optTypeStr == 'CE' || optTypeStr == 'PE') {
        optionType = optTypeStr;
      }

      // Parse lot size
      final lotStr = cols[6].trim();
      final lotSize = double.tryParse(lotStr);

      // Determine segment
      final segment = (instrType == 'FUTIDX' || instrType == 'FUTSTK')
          ? ScripSegment.futures
          : ScripSegment.options;

      // Use custom symbol as name (more readable), fallback to symbol name
      final customSymbol = cols[7].trim();
      final name = customSymbol.isNotEmpty ? customSymbol : (cols[15].trim());

      // cols[15] = SymbolName = underlying equity symbol (e.g. "TATAMOTORS")
      final symbolName = cols[15].trim();

      scrips.add(ScripInfo(
        symbol: symbol,
        name: name,
        securityId: securityId,
        segment: segment,
        exchangeSegment: 'NSE_FNO',
        instrumentType: instrType,
        expiryDate: expiryDate,
        strikePrice: strikePrice,
        optionType: optionType,
        lotSize: lotSize,
        underlyingSymbol: symbolName.isNotEmpty ? symbolName : null,
      ));
    }

    return scrips;
  }

  // ── File cache ───────────────────────────────────────────────────────
  Future<File> _getCacheFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<void> _saveToFile(List<ScripInfo> scrips, String fileName) async {
    try {
      final file = await _getCacheFile(fileName);
      await file.writeAsString(
          jsonEncode(scrips.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }

  Future<List<ScripInfo>?> _loadFromFile(String fileName) async {
    try {
      final file = await _getCacheFile(fileName);
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

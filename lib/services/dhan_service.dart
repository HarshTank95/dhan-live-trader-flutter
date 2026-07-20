import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:candlesticks/candlesticks.dart';
import 'candle_sanitizer.dart';
import 'rate_limiter.dart';
import 'scrip_service.dart';
import '../models/holding_model.dart';

// Typed exceptions for better error handling in UI
class DhanAuthException implements Exception {
  final String message;
  DhanAuthException(this.message);
}

class DhanRateLimitException implements Exception {}

class DhanNetworkException implements Exception {
  final String message;
  DhanNetworkException(this.message);
}

class StockQuote {
  final String symbol;
  final String name;
  final int securityId;
  final double ltp;
  final double open;
  final double high;
  final double low;
  final double prevClose;
  final double change;
  final double changePercent;

  StockQuote({
    required this.symbol,
    required this.name,
    required this.securityId,
    required this.ltp,
    required this.open,
    required this.high,
    required this.low,
    required this.prevClose,
  })  : change = prevClose > 0 ? ltp - prevClose : 0,
        changePercent =
            prevClose > 0 ? ((ltp - prevClose) / prevClose) * 100 : 0;

  bool get isPositive => change >= 0;
}

class DhanService {
  final String clientId;
  final String accessToken;

  static const String _baseUrl = 'https://api.dhan.co';

  List<ScripInfo> _watchlist = [];
  final Map<int, double> _prevCloses = {};

  DhanService({required this.clientId, required this.accessToken});

  void setWatchlist(List<ScripInfo> scrips) {
    _watchlist = scrips;
  }

  /// Group security IDs by exchange segment (from watchlist)
  Map<String, List<int>> _groupBySegment(List<int> securityIds) {
    final grouped = <String, List<int>>{};
    for (final id in securityIds) {
      final scrip = _watchlist.firstWhere(
        (s) => s.securityId == id,
        orElse: () => ScripInfo(symbol: '', name: '', securityId: id),
      );
      final seg = scrip.exchangeSegment;
      (grouped[seg] ??= []).add(id);
    }
    return grouped;
  }

  /// Group security IDs by exchange segment (from ScripService)
  Map<String, List<int>> _groupBySegmentFromIds(List<int> ids) {
    final grouped = <String, List<int>>{};
    final scripService = ScripService();
    for (final id in ids) {
      final scrip = scripService.findById(id);
      final seg = scrip?.exchangeSegment ?? 'NSE_EQ';
      (grouped[seg] ??= []).add(id);
    }
    return grouped;
  }

  /// Feed-authoritative prev-close (WebSocket code-6 packet). Always
  /// overwrites — the exchange's own value is ground truth. The candle-derived
  /// [loadPrevCloses] below is only the cold-start fallback for the window
  /// before the feed has delivered (and its clock-based session inference is
  /// superseded per-stock the moment a feed packet arrives).
  void updatePrevClose(int securityId, double close) {
    if (close > 0) _prevCloses[securityId] = close;
  }

  // ── Cold-start fallback: derive prev-close from daily candles ────────────
  Future<void> loadPrevCloses() async {
    if (_watchlist.isEmpty) return;

    // Fetch through tomorrow so today's completed bar is included post-close;
    // _fetchDayClose picks the correct reference session from the result.
    final toDate = DateTime.now().add(const Duration(days: 1));
    final fromDate = DateTime.now().subtract(const Duration(days: 10));

    for (final stock in _watchlist) {
      if (_prevCloses.containsKey(stock.securityId)) continue;
      try {
        // Rate limiter handles spacing — no need for manual delay
        final close = await _fetchDayClose(
            stock.securityId.toString(), _fmt(fromDate), _fmt(toDate));
        if (close > 0) _prevCloses[stock.securityId] = close;
      } catch (_) {}
    }
  }

  // ── Live OHLC fetch every 5 seconds ─────────────────────────────────
  Future<List<StockQuote>> fetchLTP() async {
    if (_watchlist.isEmpty) return [];

    // Watchman: enforce Quote API rate limit (1 req/sec)
    await RateLimiter.instance.acquire(ApiCategory.quote);

    final securityIds = _watchlist.map((s) => s.securityId).toList();

    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$_baseUrl/v2/marketfeed/ohlc'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(_groupBySegment(securityIds)),
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DhanAuthException('Access token expired or invalid. Please update your credentials.');
    }
    if (response.statusCode == 429) {
      throw DhanRateLimitException();
    }
    if (response.statusCode != 200) {
      throw Exception('API error (${response.statusCode})');
    }

    final json = jsonDecode(response.body);
    final allData = <String, dynamic>{};
    // Merge data from all segments
    for (final seg in ['NSE_EQ', 'NSE_FNO']) {
      final segData = json['data']?[seg] as Map<String, dynamic>?;
      if (segData != null) allData.addAll(segData);
    }

    return _watchlist.map((stock) {
      final data = allData[stock.securityId.toString()];
      final ohlc = data?['ohlc'] ?? {};

      return StockQuote(
        symbol: stock.symbol,
        name: stock.name,
        securityId: stock.securityId,
        ltp: (data?['last_price'] ?? 0).toDouble(),
        open: (ohlc['open'] ?? 0).toDouble(),
        high: (ohlc['high'] ?? 0).toDouble(),
        low: (ohlc['low'] ?? 0).toDouble(),
        prevClose: _prevCloses[stock.securityId] ?? 0,
      );
    }).toList();
  }

  // ── Historical daily close ───────────────────────────────────────────
  /// Resolve exchange segment for a security ID
  String _resolveSegment(int secId) {
    final scrip = ScripService().findById(secId);
    return scrip?.exchangeSegment ?? 'NSE_EQ';
  }

  /// Resolve instrument type for API calls
  String _resolveInstrument(int secId) {
    final scrip = ScripService().findById(secId);
    if (scrip == null) return 'EQUITY';
    switch (scrip.segment) {
      case ScripSegment.futures:
        return scrip.instrumentType ?? 'FUTIDX';
      case ScripSegment.options:
        return scrip.instrumentType ?? 'OPTIDX';
      default:
        return 'EQUITY';
    }
  }

  Future<double> _fetchDayClose(
      String securityId, String fromDate, String toDate) async {
    // Watchman: enforce Data API rate limit (5 req/sec, 100k/day)
    await RateLimiter.instance.acquire(ApiCategory.data);

    final secId = int.tryParse(securityId) ?? 0;
    final response = await http.post(
      Uri.parse('$_baseUrl/v2/charts/historical'),
      headers: {
        'access-token': accessToken,
        'client-id': clientId,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'securityId': securityId,
        'exchangeSegment': _resolveSegment(secId),
        'instrument': _resolveInstrument(secId),
        'expiryCode': 0,
        'oi': false,
        'fromDate': fromDate,
        'toDate': toDate,
      }),
    );

    if (response.statusCode != 200) return 0;
    final json = jsonDecode(response.body);
    final closes = json['close'] as List<dynamic>?;
    if (closes == null || closes.isEmpty) return 0;
    if (closes.length == 1) return (closes.last as num).toDouble();

    // The day-change reference is the close of the session BEFORE the one
    // that produced the current LTP (matching the WebSocket prev-close packet
    // and broker-app convention). Three cases, verified against live data:
    //  1. Today's bar IS in the response (published) → reference = the bar
    //     before it.
    //  2. Today's session has started (weekday, ≥09:15 IST) but today's bar
    //     is NOT yet published — Dhan publishes the daily bar with a delay
    //     after close, and intraday the forming bar is absent — → the last
    //     published bar IS the previous session → reference = last bar.
    //  3. Today has no session yet (weekend / pre-open morning) → the LTP is
    //     the last bar's own close → reference = the bar before it.
    // (Original bug: always taking closes.last → 0.00 change off-hours.
    //  First fix attempt collapsed cases 2+3 → off-by-one-session evenings.)
    // Known small gap: on a weekday NSE holiday, case 2 fires wrongly and
    // shows 0.00 after a manual refresh — the feed path stays correct.
    final timestamps = json['timestamp'] as List<dynamic>?;
    final nowIst =
        DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    bool lastBarIsToday = false;
    if (timestamps != null && timestamps.length == closes.length) {
      final lastBar = DateTime.fromMillisecondsSinceEpoch(
              ((timestamps.last as num) * 1000).round(),
              isUtc: true)
          .add(const Duration(hours: 5, minutes: 30));
      lastBarIsToday = lastBar.year == nowIst.year &&
          lastBar.month == nowIst.month &&
          lastBar.day == nowIst.day;
    }
    final sessionStartedToday = nowIst.weekday != DateTime.saturday &&
        nowIst.weekday != DateTime.sunday &&
        (nowIst.hour * 60 + nowIst.minute) >= 9 * 60 + 15;
    final int idx;
    if (lastBarIsToday) {
      idx = closes.length - 2; // case 1
    } else if (sessionStartedToday) {
      idx = closes.length - 1; // case 2
    } else {
      idx = closes.length - 2; // case 3
    }
    return (closes[idx] as num).toDouble();
  }

  // ── Intraday candles (for a specific date, minute intervals) ────────
  Future<List<Candle>> fetchIntraday(int securityId, String interval,
      {DateTime? date}) async {
    // Watchman: enforce Data API rate limit (5 req/sec, 100k/day)
    await RateLimiter.instance.acquire(ApiCategory.data);

    final dateStr = _fmt(date ?? DateTime.now());
    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$_baseUrl/v2/charts/intraday'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'securityId': securityId.toString(),
          'exchangeSegment': _resolveSegment(securityId),
          'instrument': _resolveInstrument(securityId),
          'interval': interval,
          'fromDate': dateStr,
          'toDate': dateStr,
        }),
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DhanAuthException('Access token expired or invalid.');
    }
    // 400 = no data for this date (market closed, holiday, pre-market)
    if (response.statusCode == 400) {
      return [];
    }
    if (response.statusCode != 200) {
      throw Exception('API error (${response.statusCode})');
    }

    return _parseCandles(response.body);
  }

  // ── Historical daily candles ─────────────────────────────────────────
  Future<List<Candle>> fetchHistoricalDailyCandles(
      int securityId, int days) async {
    // Watchman: enforce Data API rate limit (5 req/sec, 100k/day)
    await RateLimiter.instance.acquire(ApiCategory.data);

    final toDate = DateTime.now().subtract(const Duration(days: 1));
    final fromDate = DateTime.now().subtract(Duration(days: days));

    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$_baseUrl/v2/charts/historical'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'securityId': securityId.toString(),
          'exchangeSegment': _resolveSegment(securityId),
          'instrument': _resolveInstrument(securityId),
          'expiryCode': 0,
          'oi': false,
          'fromDate': _fmt(fromDate),
          'toDate': _fmt(toDate),
        }),
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode != 200) {
      throw Exception('API error (${response.statusCode})');
    }

    return _parseCandles(response.body);
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

    // Market hours: 9:15 AM to 3:30 PM IST
    const marketOpenMinutes = 9 * 60 + 15;  // 9:15 AM
    const marketCloseMinutes = 15 * 60 + 30; // 3:30 PM

    final candles = <Candle>[];
    for (int i = 0; i < opens.length; i++) {
      final dt = DateTime.fromMillisecondsSinceEpoch(timestamps[i] * 1000);
      final minuteOfDay = dt.hour * 60 + dt.minute;

      // Skip candles outside market hours (pre-market junk)
      if (minuteOfDay < marketOpenMinutes || minuteOfDay > marketCloseMinutes) {
        continue;
      }

      candles.add(Candle(
        date: dt,
        high: highs[i],
        low: lows[i],
        open: opens[i],
        close: closes[i],
        volume: i < volumes.length ? volumes[i] : 0,
      ));
    }
    // Parse boundary — sanitize every API response (see CandleSanitizer).
    final clean = CandleSanitizer.sanitize(candles, context: 'charts');
    // candlesticks package expects newest first
    return clean.reversed.toList();
  }

  // ── Funds / margin balance ───────────────────────────────────────────
  Future<Map<String, double>> fetchFunds() async {
    await RateLimiter.instance.acquire(ApiCategory.quote);

    http.Response response;
    try {
      response = await http.get(
        Uri.parse('$_baseUrl/v2/fundlimit'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Accept': 'application/json',
        },
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DhanAuthException('Access token expired or invalid.');
    }
    if (response.statusCode != 200) {
      throw Exception('API error (${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    // Note: Dhan API has a typo — "availabelBalance" (not "availableBalance")
    final available = (json['availabelBalance'] as num?)?.toDouble() ?? 0;
    final used = (json['utilizedAmount'] as num?)?.toDouble() ?? 0;
    final withdrawable = (json['withdrawableBalance'] as num?)?.toDouble() ?? 0;
    return {
      'available': available,
      'used': used,
      'total': available + used,
      'withdrawable': withdrawable,
    };
  }

  // ── Holdings (long-term portfolio) ───────────────────────────────────
  Future<List<HoldingModel>> fetchHoldings() async {
    await RateLimiter.instance.acquire(ApiCategory.data);

    http.Response response;
    try {
      response = await http.get(
        Uri.parse('$_baseUrl/v2/holdings'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DhanAuthException('Access token expired or invalid.');
    }
    // Dhan returns 500 + DH-1111 when account has no holdings — treat as empty
    if (response.statusCode == 500) {
      try {
        final err = jsonDecode(response.body) as Map<String, dynamic>;
        if (err['errorCode'] == 'DH-1111') return [];
      } catch (_) {}
      throw Exception('HTTP 500: ${response.body}');
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return [];
    return (decoded as List<dynamic>)
        .map((e) => HoldingModel.fromJson(e as Map<String, dynamic>))
        .where((h) => h.totalQty > 0)
        .toList();
  }

  // ── Live LTP for a list of security IDs (used by Holdings screen) ───
  Future<Map<int, double>> fetchOhlcForIds(List<int> ids) async {
    if (ids.isEmpty) return {};
    await RateLimiter.instance.acquire(ApiCategory.quote);

    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$_baseUrl/v2/marketfeed/ohlc'),
        headers: {
          'access-token': accessToken,
          'client-id': clientId,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(_groupBySegmentFromIds(ids)),
      );
    } catch (e) {
      throw DhanNetworkException('No internet connection or server unreachable');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DhanAuthException('Access token expired or invalid.');
    }
    if (response.statusCode != 200) return {};

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final allData = <String, dynamic>{};
    for (final seg in ['NSE_EQ', 'NSE_FNO']) {
      final segData = json['data']?[seg] as Map<String, dynamic>?;
      if (segData != null) allData.addAll(segData);
    }

    return {
      for (final entry in allData.entries)
        if (int.tryParse(entry.key) != null)
          int.parse(entry.key):
              (entry.value['last_price'] as num?)?.toDouble() ?? 0,
    };
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

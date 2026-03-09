import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:candlesticks/candlesticks.dart';
import 'rate_limiter.dart';
import 'scrip_service.dart';

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

  // ── Load yesterday's close once at startup ───────────────────────────
  Future<void> loadPrevCloses() async {
    if (_watchlist.isEmpty) return;

    final toDate = DateTime.now().subtract(const Duration(days: 1));
    final fromDate = DateTime.now().subtract(const Duration(days: 7));

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
        body: jsonEncode({'NSE_EQ': securityIds}),
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
    final nseData = json['data']['NSE_EQ'] as Map<String, dynamic>;

    return _watchlist.map((stock) {
      final data = nseData[stock.securityId.toString()];
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
  Future<double> _fetchDayClose(
      String securityId, String fromDate, String toDate) async {
    // Watchman: enforce Data API rate limit (5 req/sec, 100k/day)
    await RateLimiter.instance.acquire(ApiCategory.data);

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
        'exchangeSegment': 'NSE_EQ',
        'instrument': 'EQUITY',
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
    return (closes.last as num).toDouble();
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
          'exchangeSegment': 'NSE_EQ',
          'instrument': 'EQUITY',
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
          'exchangeSegment': 'NSE_EQ',
          'instrument': 'EQUITY',
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
    // candlesticks package expects newest first
    return candles.reversed.toList();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

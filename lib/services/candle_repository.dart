import 'dart:convert';
import 'dart:io';
import 'package:candlesticks/candlesticks.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'candle_sanitizer.dart';
import 'rate_limiter.dart';

/// Shared candle data repository backed by SQLite.
///
/// Single source of truth for historical candle data — used by:
///   - Live strategy engine (prepare phase)
///   - Backtest engine (simulation)
///   - Any future strategy or analysis tool
///
/// Smart fetching: checks cache first, only calls Dhan API for missing data.
/// Respects rate limits via the global [RateLimiter].
class CandleRepository {
  CandleRepository._();
  static final CandleRepository instance = CandleRepository._();

  Database? _db;

  static const _dbName = 'candle_cache.db';
  static const _table = 'candles';
  static const _dbVersion = 1;

  // ── Initialization ─────────────────────────────────────────────────

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$_dbName';
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            security_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            interval TEXT NOT NULL,
            open REAL NOT NULL,
            high REAL NOT NULL,
            low REAL NOT NULL,
            close REAL NOT NULL,
            volume REAL NOT NULL,
            timestamp INTEGER NOT NULL,
            PRIMARY KEY (security_id, timestamp, interval)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_candles_lookup ON $_table (security_id, date, interval)',
        );
      },
    );
  }

  // ── Public API ─────────────────────────────────────────────────────

  /// Get candles for a single stock on a single date.
  /// Returns oldest-first order.
  /// Checks cache first; fetches from API if missing.
  Future<List<Candle>> getCandles({
    required int securityId,
    required DateTime date,
    required String interval,
    required String accessToken,
    required String clientId,
  }) async {
    final dateStr = _fmt(date);

    // Check cache
    final cached = await _loadFromCache(securityId, dateStr, interval);
    if (cached.isNotEmpty) return cached;

    // Fetch from API
    final candles = await _fetchFromApi(
      securityId: securityId,
      fromDate: date,
      toDate: date,
      interval: interval,
      accessToken: accessToken,
      clientId: clientId,
    );

    // Cache what we got
    if (candles.isNotEmpty) {
      await _saveToCache(securityId, interval, candles);
    }

    return candles;
  }

  /// Bulk fetch candles for multiple stocks over a date range.
  /// Optimized: uses single API call per stock for the full range (up to 90 days).
  /// Splits into 90-day windows for longer ranges.
  ///
  /// [onProgress] reports (completed, total) for UI progress tracking.
  /// [onLog] optional logging callback.
  /// Returns a map of securityId → all candles (oldest first).
  Future<Map<int, List<Candle>>> bulkFetch({
    required List<int> securityIds,
    required DateTime fromDate,
    required DateTime toDate,
    required String interval,
    required String accessToken,
    required String clientId,
    void Function(int completed, int total, String status)? onProgress,
    void Function(String message)? onLog,
    bool Function()? isCancelled,
  }) async {
    final result = <int, List<Candle>>{};
    final total = securityIds.length;

    for (int i = 0; i < securityIds.length; i++) {
      if (isCancelled?.call() == true) break;

      final secId = securityIds[i];
      try {
        final candles = await _fetchRange(
          securityId: secId,
          fromDate: fromDate,
          toDate: toDate,
          interval: interval,
          accessToken: accessToken,
          clientId: clientId,
        );
        if (candles.isNotEmpty) {
          result[secId] = candles;
        }
      } catch (e) {
        onLog?.call('Error fetching $secId: $e');
      }

      // Yield to event loop every iteration so UI stays responsive
      // (progress updates render, cancel button works)
      await Future.delayed(Duration.zero);

      if ((i + 1) % 5 == 0 || i == total - 1) {
        onProgress?.call(i + 1, total, 'Downloaded ${i + 1}/$total stocks');
      }
    }

    return result;
  }

  /// Interval key used to cache DAILY candles (separate namespace from the
  /// intraday '5'/'15'/etc. keys so they never collide in the SQLite table).
  static const dailyInterval = '1day';

  /// Bulk fetch DAILY candles for multiple stocks over a date range.
  /// Used by Gap Fade (needs daily ATR/SMA/prevClose/prevLow/avg-volume).
  /// Returns securityId → daily candles (oldest first). Cached under the
  /// [dailyInterval] key.
  Future<Map<int, List<Candle>>> bulkFetchDaily({
    required List<int> securityIds,
    required DateTime fromDate,
    required DateTime toDate,
    required String accessToken,
    required String clientId,
    void Function(int completed, int total, String status)? onProgress,
    void Function(String message)? onLog,
    bool Function()? isCancelled,
  }) async {
    final result = <int, List<Candle>>{};
    final total = securityIds.length;

    for (int i = 0; i < securityIds.length; i++) {
      if (isCancelled?.call() == true) break;
      final secId = securityIds[i];
      try {
        final candles = await _fetchDailyRange(
          securityId: secId,
          fromDate: fromDate,
          toDate: toDate,
          accessToken: accessToken,
          clientId: clientId,
        );
        if (candles.isNotEmpty) result[secId] = candles;
      } catch (e) {
        onLog?.call('Error fetching daily $secId: $e');
      }
      await Future.delayed(Duration.zero);
      if ((i + 1) % 5 == 0 || i == total - 1) {
        onProgress?.call(i + 1, total, 'Daily $i/$total');
      }
    }
    return result;
  }

  /// Daily candles for one stock over a range (cache-first). Mirrors
  /// [_fetchRange] but hits the daily endpoint and skips the intraday
  /// market-hours filter.
  Future<List<Candle>> _fetchDailyRange({
    required int securityId,
    required DateTime fromDate,
    required DateTime toDate,
    required String accessToken,
    required String clientId,
  }) async {
    // ONE range query per stock. The previous per-day lookup issued one
    // SQLite query per weekday per stock (500 stocks × ~350 days = 175k
    // queries on a 1-year run) and made the prep phase look frozen.
    final allCandles = await _loadRangeFromCache(
        securityId, _fmt(fromDate), _fmt(toDate), dailyInterval);
    final cachedDays = allCandles.map((c) => _fmt(c.date)).toSet();

    final missingDates = <DateTime>[];
    var current = fromDate;
    while (!current.isAfter(toDate)) {
      if (current.weekday != DateTime.saturday &&
          current.weekday != DateTime.sunday &&
          !cachedDays.contains(_fmt(current))) {
        missingDates.add(current);
      }
      current = current.add(const Duration(days: 1));
    }

    if (missingDates.isEmpty) {
      allCandles.sort((a, b) => a.date.compareTo(b.date));
      return allCandles;
    }

    // Daily endpoint allows multi-year ranges; chunk at 365 days to be safe.
    final windows = _splitWindows(missingDates.first, missingDates.last, 365);
    for (final window in windows) {
      final fetched = await _fetchDailyFromApi(
        securityId: securityId,
        fromDate: window.$1,
        toDate: window.$2,
        accessToken: accessToken,
        clientId: clientId,
      );
      if (fetched.isNotEmpty) {
        await _saveToCache(securityId, dailyInterval, fetched);
        // Only keep the days within the requested [fromDate, toDate].
        for (final c in fetched) {
          if (!c.date.isBefore(fromDate) &&
              !c.date.isAfter(toDate.add(const Duration(days: 1)))) {
            allCandles.add(c);
          }
        }
      }
    }

    // De-dupe (cache + freshly fetched can overlap) by calendar day.
    final byDay = <String, Candle>{};
    for (final c in allCandles) {
      byDay[_fmt(c.date)] = c;
    }
    final out = byDay.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  Future<List<Candle>> _fetchDailyFromApi({
    required int securityId,
    required DateTime fromDate,
    required DateTime toDate,
    required String accessToken,
    required String clientId,
  }) async {
    await RateLimiter.instance.acquire(ApiCategory.data);

    const maxRetries = 3;
    var retryDelay = 2000;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse('https://api.dhan.co/v2/charts/historical'),
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
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 400) return [];
        if (response.statusCode == 429 && attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
          continue;
        }
        if (response.statusCode != 200) {
          try {
            final body = jsonDecode(response.body);
            if (body is Map &&
                (body['errorCode'] == '805' || body['errorCode'] == 'DH-904') &&
                attempt < maxRetries) {
              await Future.delayed(Duration(milliseconds: retryDelay));
              retryDelay *= 2;
              continue;
            }
          } catch (_) {}
          return [];
        }
        // Parse boundary — see CandleSanitizer.
        return CandleSanitizer.sanitize(_parseDailyCandles(response.body),
            context: 'daily/$securityId');
      } catch (e) {
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
        }
      }
    }
    return [];
  }

  /// Parse daily candles. Unlike intraday, there is no market-hours filter
  /// (daily bars are stamped at 00:00 IST). The trading day is computed from
  /// the IST wall-clock so it is correct regardless of device timezone.
  List<Candle> _parseDailyCandles(String body) {
    final json = jsonDecode(body);
    final opens = (json['open'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final highs = (json['high'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final lows = (json['low'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final closes = (json['close'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final volumes = (json['volume'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final timestamps = (json['timestamp'] as List<dynamic>?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        [];

    if (opens.isEmpty) return [];

    final candles = <Candle>[];
    for (int i = 0; i < opens.length; i++) {
      // Dhan stamps a daily bar at 00:00 IST = 18:30 UTC of the prior day.
      // Convert to the IST calendar day explicitly so the date is correct on
      // any device timezone, then store as a local-midnight DateTime to match
      // the rest of the cache.
      final utc =
          DateTime.fromMillisecondsSinceEpoch(timestamps[i] * 1000, isUtc: true);
      final ist = utc.add(const Duration(hours: 5, minutes: 30));
      final date = DateTime(ist.year, ist.month, ist.day);
      candles.add(Candle(
        date: date,
        high: highs[i],
        low: lows[i],
        open: opens[i],
        close: closes[i],
        volume: i < volumes.length ? volumes[i] : 0,
      ));
    }
    candles.sort((a, b) => a.date.compareTo(b.date));
    return candles;
  }

  /// Fetch candles for a single stock over a date range.
  /// Checks cache day-by-day, only fetches missing days from API.
  /// For API calls, uses max 90-day windows to minimize call count.
  Future<List<Candle>> _fetchRange({
    required int securityId,
    required DateTime fromDate,
    required DateTime toDate,
    required String interval,
    required String accessToken,
    required String clientId,
  }) async {
    // Collect all trading days in range
    final allCandles = <Candle>[];
    final missingDates = <DateTime>[];

    var current = fromDate;
    while (!current.isAfter(toDate)) {
      if (current.weekday != DateTime.saturday &&
          current.weekday != DateTime.sunday) {
        final dateStr = _fmt(current);
        final cached = await _loadFromCache(securityId, dateStr, interval);
        if (cached.isNotEmpty) {
          allCandles.addAll(cached);
        } else {
          missingDates.add(current);
        }
      }
      current = current.add(const Duration(days: 1));
    }

    if (missingDates.isEmpty) {
      // Merge boundary: cached days are individually clean, but the assembled
      // multi-day list must still hold the unique-and-sorted invariant.
      return CandleSanitizer.sanitize(allCandles,
          context: '$interval/$securityId merge');
    }

    // Fetch missing dates in 90-day windows
    final windows = _split90DayWindows(missingDates.first, missingDates.last);
    for (final window in windows) {
      final fetched = await _fetchFromApi(
        securityId: securityId,
        fromDate: window.$1,
        toDate: window.$2,
        interval: interval,
        accessToken: accessToken,
        clientId: clientId,
      );
      if (fetched.isNotEmpty) {
        await _saveToCache(securityId, interval, fetched);
        allCandles.addAll(fetched);
      }
    }

    // Merge boundary: fetched windows can overlap days already loaded from
    // cache; sanitize the assembled list (dedupe keeps the cache's pick).
    return CandleSanitizer.sanitize(allCandles,
        context: '$interval/$securityId merge');
  }

  /// Get candles for a stock grouped by date. Used by backtest engine.
  /// Returns map of date string → candles (oldest first).
  Future<Map<String, List<Candle>>> getCandlesByDate({
    required int securityId,
    required DateTime fromDate,
    required DateTime toDate,
    required String interval,
    required String accessToken,
    required String clientId,
  }) async {
    final allCandles = await _fetchRange(
      securityId: securityId,
      fromDate: fromDate,
      toDate: toDate,
      interval: interval,
      accessToken: accessToken,
      clientId: clientId,
    );

    final byDate = <String, List<Candle>>{};
    for (final candle in allCandles) {
      final dateStr = _fmt(candle.date);
      byDate.putIfAbsent(dateStr, () => []).add(candle);
    }

    return byDate;
  }

  /// Check how many trading days are cached for a stock.
  Future<int> getCachedDayCount(int securityId, String interval) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(DISTINCT date) as cnt FROM $_table WHERE security_id = ? AND interval = ?',
      [securityId, interval],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get cache statistics.
  Future<Map<String, dynamic>> getCacheStats() async {
    final db = await _database;
    final totalCandles = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $_table')) ??
        0;
    final totalStocks = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(DISTINCT security_id) FROM $_table')) ??
        0;
    final totalDays = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(DISTINCT date) FROM $_table')) ??
        0;

    final dbSize = await _getDatabaseSize();

    return {
      'totalCandles': totalCandles,
      'totalStocks': totalStocks,
      'totalDays': totalDays,
      'dbSizeMB': (dbSize / (1024 * 1024)).toStringAsFixed(1),
    };
  }

  /// Clear all cached candles.
  Future<void> clearCache() async {
    final db = await _database;
    await db.delete(_table);
  }

  /// Clear candles older than [before].
  Future<int> clearOlderThan(DateTime before) async {
    final db = await _database;
    return db.delete(
      _table,
      where: 'date < ?',
      whereArgs: [_fmt(before)],
    );
  }

  // ── Private: Cache Operations ─────────────────────────────────────

  /// Load all cached candles for [securityId] in [fromStr, toStr] (inclusive)
  /// with one query, oldest first.
  Future<List<Candle>> _loadRangeFromCache(
      int securityId, String fromStr, String toStr, String interval) async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'security_id = ? AND interval = ? AND date >= ? AND date <= ?',
      whereArgs: [securityId, interval, fromStr, toStr],
      orderBy: 'timestamp ASC',
    );
    return rows
        .map((row) => Candle(
              date: DateTime.fromMillisecondsSinceEpoch(
                  (row['timestamp'] as int) * 1000),
              open: row['open'] as double,
              high: row['high'] as double,
              low: row['low'] as double,
              close: row['close'] as double,
              volume: row['volume'] as double,
            ))
        .toList();
  }

  Future<List<Candle>> _loadFromCache(
      int securityId, String dateStr, String interval) async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'security_id = ? AND date = ? AND interval = ?',
      whereArgs: [securityId, dateStr, interval],
      orderBy: 'timestamp ASC',
    );

    if (rows.isEmpty) return [];

    return rows.map((row) {
      return Candle(
        date: DateTime.fromMillisecondsSinceEpoch(
            (row['timestamp'] as int) * 1000),
        open: row['open'] as double,
        high: row['high'] as double,
        low: row['low'] as double,
        close: row['close'] as double,
        volume: row['volume'] as double,
      );
    }).toList();
  }

  Future<void> _saveToCache(
      int securityId, String interval, List<Candle> candles) async {
    if (candles.isEmpty) return;
    final db = await _database;

    final batch = db.batch();
    for (final c in candles) {
      final dateStr = _fmt(c.date);
      final ts = c.date.millisecondsSinceEpoch ~/ 1000;
      batch.insert(
        _table,
        {
          'security_id': securityId,
          'date': dateStr,
          'interval': interval,
          'open': c.open,
          'high': c.high,
          'low': c.low,
          'close': c.close,
          'volume': c.volume,
          'timestamp': ts,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  // ── Private: API Fetching ──────────────────────────────────────────

  Future<List<Candle>> _fetchFromApi({
    required int securityId,
    required DateTime fromDate,
    required DateTime toDate,
    required String interval,
    required String accessToken,
    required String clientId,
  }) async {
    // Respect global rate limiter
    await RateLimiter.instance.acquire(ApiCategory.data);

    final fromStr = '${_fmt(fromDate)} 09:15:00';
    final toStr = '${_fmt(toDate)} 15:30:00';

    const maxRetries = 3;
    var retryDelay = 2000;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await http.post(
          Uri.parse('https://api.dhan.co/v2/charts/intraday'),
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
            'oi': false,
            'fromDate': fromStr,
            'toDate': toStr,
          }),
        ).timeout(const Duration(seconds: 15));

        // No data for this date range (holiday, not listed, etc.)
        if (response.statusCode == 400) return [];

        // Rate limited by Dhan — retry with backoff
        if (response.statusCode == 429 && attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
          continue;
        }

        if (response.statusCode != 200) {
          // Dhan error code 805 — too many requests, risk of being blocked
          try {
            final body = jsonDecode(response.body);
            if (body is Map &&
                (body['errorCode'] == '805' ||
                    body['errorCode'] == 'DH-904')) {
              if (attempt < maxRetries) {
                await Future.delayed(Duration(milliseconds: retryDelay));
                retryDelay *= 2;
                continue;
              }
            }
          } catch (_) {}
          return [];
        }

        // Parse boundary: API responses must never leak duplicates or
        // malformed bars into the system.
        return CandleSanitizer.sanitize(_parseCandles(response.body),
            context: 'intraday/$securityId');
      } catch (e) {
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelay));
          retryDelay *= 2;
        }
      }
    }

    return [];
  }

  List<Candle> _parseCandles(String body) {
    final json = jsonDecode(body);
    final opens = (json['open'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final highs = (json['high'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final lows = (json['low'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final closes = (json['close'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final volumes = (json['volume'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final timestamps = (json['timestamp'] as List<dynamic>?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        [];

    if (opens.isEmpty) return [];

    const marketOpenMinutes = 9 * 60 + 15; // 9:15 AM
    const marketCloseMinutes = 15 * 60 + 30; // 3:30 PM

    final candles = <Candle>[];
    for (int i = 0; i < opens.length; i++) {
      final dt = DateTime.fromMillisecondsSinceEpoch(timestamps[i] * 1000);
      final minuteOfDay = dt.hour * 60 + dt.minute;

      if (minuteOfDay < marketOpenMinutes ||
          minuteOfDay > marketCloseMinutes) {
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

    // Return oldest first (consistent for strategy logic)
    candles.sort((a, b) => a.date.compareTo(b.date));
    return candles;
  }

  // ── Private: Helpers ───────────────────────────────────────────────

  /// Split a date range into 90-day windows for API calls.
  List<(DateTime, DateTime)> _split90DayWindows(DateTime from, DateTime to) =>
      _splitWindows(from, to, 90);

  /// Split a date range into windows of at most [maxDays] calendar days.
  List<(DateTime, DateTime)> _splitWindows(
      DateTime from, DateTime to, int maxDays) {
    final windows = <(DateTime, DateTime)>[];
    var windowStart = from;

    while (!windowStart.isAfter(to)) {
      var windowEnd = windowStart.add(Duration(days: maxDays - 1));
      if (windowEnd.isAfter(to)) windowEnd = to;
      windows.add((windowStart, windowEnd));
      windowStart = windowEnd.add(const Duration(days: 1));
    }

    return windows;
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<int> _getDatabaseSize() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_dbName');
      if (await file.exists()) return await file.length();
    } catch (_) {}
    return 0;
  }
}

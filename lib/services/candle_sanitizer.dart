import 'package:candlesticks/candlesticks.dart';
import 'app_logger.dart';

/// Single choke point for candle data quality.
///
/// Every candle list that enters the system — any API response parse and any
/// multi-source merge (cache + fresh fetch) — MUST pass through [sanitize].
/// Downstream code (strategies, engines, charts) is then allowed to assume:
///
///   1. timestamps are unique (no duplicate bars),
///   2. bars are internally consistent (high ≥ low, high ≥ open/close ≥ low,
///      all prices > 0),
///   3. the list is sorted oldest-first.
///
/// Why this exists: Dhan window responses occasionally contain the same bar
/// twice — sometimes an identical copy, rarely a corrupt duplicate at a
/// different price (run-167 reconciliation, 2026-06-12: LICI carried a bogus
/// half-price duplicate). The SQLite cache silently absorbed duplicates via
/// its primary key while the raw in-memory list kept them, so backtest and
/// live saw different data than the cache. A duplicated bar then became its
/// own "next bar" — defeating next-bar-confirmation entries and stop-distance
/// filters (DIXON 2026-05-13) — and re-processing a bar inside an exit walk
/// fired trailing stops one bar early (ATGL 2026-05-15).
class CandleSanitizer {
  CandleSanitizer._();

  /// Returns a cleaned copy of [candles]: invalid bars dropped, duplicate
  /// timestamps collapsed (first occurrence wins, matching the SQLite cache's
  /// INSERT-OR-IGNORE semantics so memory and cache always agree), sorted
  /// oldest-first.
  ///
  /// [context] names the data source in the warning log (e.g. 'intraday 21690'
  /// or 'daily 1333') so a noisy symbol is identifiable from the log alone.
  static List<Candle> sanitize(List<Candle> candles, {String? context}) {
    if (candles.isEmpty) return candles;

    int invalid = 0;
    final byTs = <int, Candle>{};
    for (final c in candles) {
      if (!isValid(c)) {
        invalid++;
        continue;
      }
      byTs.putIfAbsent(c.date.millisecondsSinceEpoch, () => c);
    }

    final duplicates = candles.length - invalid - byTs.length;
    if (invalid > 0 || duplicates > 0) {
      AppLogger.warn(
          'CandleSanitizer',
          'Dropped $invalid invalid + $duplicates duplicate bar(s) of '
              '${candles.length}${context != null ? " [$context]" : ""}');
    }

    final out = byTs.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// A bar is valid when its OHLC values are positive and internally
  /// consistent. Volume may legitimately be 0 (illiquid 5-min bars).
  static bool isValid(Candle c) {
    if (c.open <= 0 || c.high <= 0 || c.low <= 0 || c.close <= 0) return false;
    if (c.high < c.low) return false;
    if (c.high < c.open || c.high < c.close) return false;
    if (c.low > c.open || c.low > c.close) return false;
    return true;
  }
}

import 'dart:collection';

/// API categories based on Dhan's official rate limits.
/// Source: https://dhanhq.co/docs/v2/
enum ApiCategory {
  /// Market feed endpoints: /v2/marketfeed/*
  /// Limit: 1 req/sec, unlimited/day
  quote,

  /// Chart endpoints: /v2/charts/intraday, /v2/charts/historical
  /// Limit: 5 req/sec, 100,000/day
  data,
}

class _RateLimitRule {
  final int perSecond;
  final int? perDay;
  const _RateLimitRule({required this.perSecond, this.perDay});
}

/// Centralized rate limiter for all Dhan API calls.
///
/// Usage:
///   await RateLimiter.instance.acquire(ApiCategory.quote);
///   // ... make API call
///
/// The limiter uses a sliding window algorithm per category.
/// If the per-second limit is reached, it automatically waits
/// the minimum time needed before allowing the call through.
/// If the daily limit is reached, it throws [RateLimitDailyException].
class RateLimiter {
  RateLimiter._internal();
  static final RateLimiter instance = RateLimiter._internal();

  static const _rules = {
    ApiCategory.quote: _RateLimitRule(perSecond: 1),
    ApiCategory.data:  _RateLimitRule(perSecond: 5, perDay: 100000),
  };

  // Sliding windows — stores timestamps of recent requests
  final _windows = <ApiCategory, Queue<DateTime>>{
    ApiCategory.quote: Queue(),
    ApiCategory.data:  Queue(),
  };

  // Daily counters
  final _dayCounts = <ApiCategory, int>{
    ApiCategory.quote: 0,
    ApiCategory.data:  0,
  };

  DateTime _dayStart = DateTime.now();

  // ── Public API ──────────────────────────────────────────────────────

  /// Acquire a slot for [category]. Waits if needed to stay within limits.
  /// Throws [RateLimitDailyException] if the daily cap is exceeded.
  Future<void> acquire(ApiCategory category) async {
    _resetDayIfNeeded();

    final rule = _rules[category]!;

    // Check daily limit
    if (rule.perDay != null) {
      final count = _dayCounts[category] ?? 0;
      if (count >= rule.perDay!) {
        throw RateLimitDailyException(
          'Daily limit of ${rule.perDay} requests reached for '
          '${category.name} API. Resets at midnight.',
        );
      }
    }

    // Sliding window: enforce per-second limit
    await _acquirePerSecond(category, rule.perSecond);

    // Record this request
    _dayCounts[category] = (_dayCounts[category] ?? 0) + 1;
  }

  /// Current stats — useful for debugging and monitoring.
  RateLimiterStats get stats {
    _resetDayIfNeeded();
    return RateLimiterStats(
      quoteCallsToday: _dayCounts[ApiCategory.quote] ?? 0,
      dataCallsToday:  _dayCounts[ApiCategory.data] ?? 0,
      dataCallsLimit:  _rules[ApiCategory.data]!.perDay!,
      quoteWindowCount: _windows[ApiCategory.quote]!.length,
      dataWindowCount:  _windows[ApiCategory.data]!.length,
      dayStart: _dayStart,
    );
  }

  /// Reset all counters (useful for testing).
  void reset() {
    _windows[ApiCategory.quote]!.clear();
    _windows[ApiCategory.data]!.clear();
    _dayCounts[ApiCategory.quote] = 0;
    _dayCounts[ApiCategory.data]  = 0;
    _dayStart = DateTime.now();
  }

  // ── Private helpers ─────────────────────────────────────────────────

  Future<void> _acquirePerSecond(ApiCategory category, int limit) async {
    final queue = _windows[category]!;

    // Allow up to 3 attempts in case of timing edge cases
    for (int attempt = 0; attempt < 3; attempt++) {
      final now = DateTime.now();
      final windowStart = now.subtract(const Duration(seconds: 1));

      // Remove timestamps outside the 1-second window
      while (queue.isNotEmpty && queue.first.isBefore(windowStart)) {
        queue.removeFirst();
      }

      if (queue.length < limit) {
        // Slot available — record and proceed
        queue.addLast(DateTime.now());
        return;
      }

      // At limit — calculate exact wait time until oldest entry expires
      final oldestEntry = queue.first;
      final waitUntil = oldestEntry.add(const Duration(seconds: 1));
      final waitMs = waitUntil.difference(DateTime.now()).inMilliseconds;

      if (waitMs > 0) {
        // Add a small buffer to avoid edge-case re-entry
        await Future.delayed(Duration(milliseconds: waitMs + 20));
      }
    }

    // Fallback: just record and proceed
    queue.addLast(DateTime.now());
  }

  void _resetDayIfNeeded() {
    final now = DateTime.now();
    if (now.day != _dayStart.day ||
        now.month != _dayStart.month ||
        now.year != _dayStart.year) {
      _dayStart = now;
      _dayCounts.updateAll((_, __) => 0);
    }
  }
}

// ── Supporting types ──────────────────────────────────────────────────

class RateLimitDailyException implements Exception {
  final String message;
  RateLimitDailyException(this.message);
  @override
  String toString() => message;
}

class RateLimiterStats {
  final int quoteCallsToday;
  final int dataCallsToday;
  final int dataCallsLimit;
  final int quoteWindowCount;
  final int dataWindowCount;
  final DateTime dayStart;

  const RateLimiterStats({
    required this.quoteCallsToday,
    required this.dataCallsToday,
    required this.dataCallsLimit,
    required this.quoteWindowCount,
    required this.dataWindowCount,
    required this.dayStart,
  });

  double get dataUsagePercent => (dataCallsToday / dataCallsLimit) * 100;
  int get dataCallsRemaining => dataCallsLimit - dataCallsToday;

  @override
  String toString() =>
      'Quote: $quoteCallsToday today | '
      'Data: $dataCallsToday/$dataCallsLimit today '
      '(${dataUsagePercent.toStringAsFixed(1)}%)';
}

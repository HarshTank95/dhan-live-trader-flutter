import 'package:candlesticks/candlesticks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/strategies/hammer_dominance_strategy.dart';

void main() {
  final strat = HammerDominanceStrategy();
  final p = HammerParams(strat.defaultParams);

  /// 30 daily bars riding a clean rising line v(t) = 100 + 0.5t: swing-low
  /// pivots sit exactly ON the line at t = 2, 9, 16 (≥5 bars apart); every
  /// other bar's low floats 3₹ above it.
  List<Candle> cleanSeries({double breakCloseAt = -1}) {
    final bars = <Candle>[];
    for (int t = 0; t < 30; t++) {
      final line = 100 + 0.5 * t;
      final isPivot = t == 2 || t == 9 || t == 16;
      final low = isPivot ? line : line + 3;
      var close = low + 2;
      if (t == breakCloseAt) close = line - 2; // close THROUGH the line
      bars.add(Candle(
        date: DateTime(2026, 1, 1).add(Duration(days: t)),
        open: low + 1,
        high: close + 2,
        low: low,
        close: close,
        volume: 100000,
      ));
    }
    return bars;
  }

  group('computeTrendlines', () {
    test('finds the rising line and projects it to TODAY (price × time)', () {
      final tls = strat.computeTrendlines(cleanSeries(), p);
      expect(tls, isNotEmpty);
      // v(today) = 100 + 0.5 × 30 = 115 — the line's value at the NEXT bar,
      // not at any historical touch. This is the time-dependence under test.
      expect(tls.first.lo, closeTo(115.0, 0.01));
      expect(tls.first.touches, greaterThanOrEqualTo(2));
      expect(tls.first.tag, startsWith('TL 115.00'));
    });

    test('near-duplicate pivot pairs collapse to a single line', () {
      // Pairs (2,9), (2,16), (9,16) all describe the same line.
      final tls = strat.computeTrendlines(cleanSeries(), p);
      expect(tls.length, 1);
    });

    test('a close through the line invalidates it (broken support)', () {
      final tls = strat.computeTrendlines(cleanSeries(breakCloseAt: 20), p);
      expect(tls, isEmpty);
    });

    test('too little history yields no lines', () {
      final tls = strat.computeTrendlines(cleanSeries().sublist(0, 8), p);
      expect(tls, isEmpty);
    });
  });
}

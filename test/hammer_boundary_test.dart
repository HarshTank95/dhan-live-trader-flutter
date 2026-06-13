import 'package:candlesticks/candlesticks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/strategies/hammer_dominance_strategy.dart';

Candle bar(
  DateTime t, {
  required double o,
  required double h,
  required double l,
  required double c,
  double v = 10000,
}) =>
    Candle(date: t, open: o, high: h, low: l, close: c, volume: v);

void main() {
  final strat = HammerDominanceStrategy();
  final params = strat.defaultParams;

  group('decimal-parity tolerant comparisons', () {
    test('ltTol: at-the-boundary is NOT less (C# decimal semantics)', () {
      // The ASHOKLEY 2026-05-14 regression: stop distance of exactly 0.80%
      // computed in doubles as 0.7999999…, falsely failing `< 0.80`.
      final sdp = (153.75 - 152.52) / 153.75 * 100; // exactly 0.8 in decimal
      expect(HammerDominanceStrategy.ltTol(sdp, 0.8), isFalse);
    });

    test('ltTol/gtTol still distinguish genuinely different values', () {
      expect(HammerDominanceStrategy.ltTol(0.79, 0.8), isTrue);
      expect(HammerDominanceStrategy.gtTol(0.81, 0.8), isTrue);
      expect(HammerDominanceStrategy.gtTol(0.8, 0.8), isFalse);
    });

    test('leTol: at-the-boundary IS ≤ (exact-tick rejection keeps firing)', () {
      expect(HammerDominanceStrategy.leTol(0.06, 0.06), isTrue);
      expect(HammerDominanceStrategy.leTol(0.0601, 0.06), isFalse);
    });
  });

  group('trigger geometry at exact boundaries', () {
    final t = DateTime(2026, 5, 14, 10, 0);

    test('dominance with body exactly 80% of range qualifies', () {
      // range 10, body 8 (80%), wicks 1 + 1 (10% each ≥ 5%)
      final c = bar(t, o: 101, h: 110, l: 100, c: 109);
      expect(strat.isDominance(c, 10, 8, 1, 1, HammerParams(params)), isTrue);
    });

    test('dominance with a wick exactly 5% of range qualifies', () {
      // range 10, body 8.5, upper wick 0.5 (5%), lower 1.0
      final c = bar(t, o: 101, h: 110.0, l: 100, c: 109.5);
      expect(
          strat.isDominance(c, 10, 8.5, 0.5, 1.0, HammerParams(params)), isTrue);
    });

    test('hammer with lower wick exactly 2x body qualifies', () {
      // body 1, lower wick 2, upper wick 0.3 (range 3.3): wick/body = 2.0
      final c = bar(t, o: 102.3, h: 103.3 + 0.0, l: 100.0, c: 103.0);
      final range = c.high - c.low;
      final body = (c.close - c.open).abs();
      final lower = (c.open < c.close ? c.open : c.close) - c.low;
      final upper = c.high - (c.open > c.close ? c.open : c.close);
      expect(strat.isHammer(c, range, body, lower, upper, HammerParams(params)),
          isTrue);
    });
  });

  group('scanForTrigger stop-distance boundary (ASHOKLEY regression)', () {
    test('stop distance exactly at the minimum is accepted', () {
      final d = DateTime(2026, 5, 14);
      DateTime at(int h, int m) => DateTime(d.year, d.month, d.day, h, m);
      // Trigger: green dominance probing a level at 100 from above,
      // engineered so (k+1 open − low) / open == exactly minStopDistancePct.
      // low = 100.15 (0.15% above the level → outside the 0.06% exact-tick
      // stop-hunt zone, inside the 0.2% tolerance band), close > 100.
      // k+1 open = low / (1 − 0.008) → stop distance exactly 0.8%.
      final low = 100.15;
      final entryOpen = low / (1 - 0.008);
      final trigger = bar(at(10, 0), o: 100.25, h: 101.07, l: low, c: 101.02);
      final next = bar(at(10, 5), o: entryOpen, h: 101.5, l: 100.7, c: 101.2);
      final later = bar(at(10, 10), o: 101.2, h: 101.4, l: 100.9, c: 101.1);

      final res = strat.scanForTrigger(
        todayCandles: [trigger, next, later],
        levels: const [SupportLevel(100, 100, 1, 'RN 100.00')],
        prevDayAvgRange: 1.0,
        params: {...params, 'supportUseRoundNumbers': false},
      );
      // The geometry of `trigger` is a valid dominance candle at support;
      // the stop distance computes to exactly 0.8% (a hair under in doubles).
      // C# decimal semantics: 0.8 < 0.8 is false → must be ACCEPTED.
      expect(res.passed, isTrue, reason: res.rejectDetail);
    });
  });
}

import 'package:candlesticks/candlesticks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/candle_sanitizer.dart';

Candle bar(
  DateTime t, {
  double o = 100,
  double h = 102,
  double l = 99,
  double c = 101,
  double v = 1000,
}) =>
    Candle(date: t, open: o, high: h, low: l, close: c, volume: v);

void main() {
  final t0 = DateTime(2026, 5, 13, 10, 10);
  final t1 = DateTime(2026, 5, 13, 10, 15);
  final t2 = DateTime(2026, 5, 13, 10, 20);

  group('CandleSanitizer.sanitize', () {
    test('passes clean data through unchanged', () {
      final input = [bar(t0), bar(t1), bar(t2)];
      final out = CandleSanitizer.sanitize(input);
      expect(out.length, 3);
      expect(out.map((c) => c.date), [t0, t1, t2]);
    });

    test('drops exact duplicate timestamps, first occurrence wins', () {
      // The DIXON 2026-05-13 case: the same bar twice made the duplicate act
      // as its own "next bar", defeating next-bar-confirmation entries.
      final input = [bar(t0, c: 101), bar(t0, c: 999, h: 999), bar(t1)];
      final out = CandleSanitizer.sanitize(input);
      expect(out.length, 2);
      expect(out[0].close, 101); // first occurrence kept
      expect(out[1].date, t1);
    });

    test('drops corrupt duplicate at a different price scale', () {
      // The LICI 2026-05-14 case: a bogus half-price copy of a bar.
      final real = bar(t0, o: 800, h: 802, l: 798, c: 801);
      final bogus = bar(t0, o: 400, h: 400.2, l: 399.65, c: 400);
      final out = CandleSanitizer.sanitize([real, bogus, bar(t1, o: 800, h: 805, l: 799, c: 803)]);
      expect(out.length, 2);
      expect(out[0].open, 800);
    });

    test('sorts oldest-first regardless of input order', () {
      final out = CandleSanitizer.sanitize([bar(t2), bar(t0), bar(t1)]);
      expect(out.map((c) => c.date), [t0, t1, t2]);
    });

    test('drops bars with non-positive prices', () {
      final out = CandleSanitizer.sanitize([
        bar(t0, o: 0),
        bar(t1, l: -5),
        bar(t2),
      ]);
      expect(out.length, 1);
      expect(out[0].date, t2);
    });

    test('drops internally inconsistent bars (high < low, OHLC outside range)',
        () {
      final out = CandleSanitizer.sanitize([
        bar(t0, h: 98, l: 99), // high < low
        bar(t1, o: 103),       // open above high
        bar(t2, c: 98.5),      // close below low
      ]);
      expect(out, isEmpty);
    });

    test('keeps zero-volume bars (legitimately illiquid)', () {
      final out = CandleSanitizer.sanitize([bar(t0, v: 0)]);
      expect(out.length, 1);
    });

    test('empty input returns empty', () {
      expect(CandleSanitizer.sanitize(const []), isEmpty);
    });
  });

  group('CandleSanitizer.isValid', () {
    test('accepts a normal bar', () {
      expect(CandleSanitizer.isValid(bar(t0)), isTrue);
    });
    test('accepts a flat bar (o=h=l=c)', () {
      expect(
          CandleSanitizer.isValid(bar(t0, o: 100, h: 100, l: 100, c: 100)),
          isTrue);
    });
    test('rejects high < low', () {
      expect(CandleSanitizer.isValid(bar(t0, h: 90, l: 95)), isFalse);
    });
  });
}

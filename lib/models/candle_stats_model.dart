/// Pre-computed historical metrics for a stock.
/// Calculated from N days of 5-min intraday candles before market open.
class CandleStatsModel {
  final int securityId;
  final String symbol;
  final double avgCandleSize; // mean of (high - low)
  final double avgVolume; // mean volume across all 5-min candles
  final double prevClose; // most recent candle's close
  final int totalCandles; // number of candles used

  const CandleStatsModel({
    required this.securityId,
    required this.symbol,
    required this.avgCandleSize,
    required this.avgVolume,
    required this.prevClose,
    required this.totalCandles,
  });
}

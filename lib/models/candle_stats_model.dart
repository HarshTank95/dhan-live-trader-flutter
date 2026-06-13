/// Pre-computed historical metrics for a stock.
/// Calculated from N days of 5-min intraday candles before market open.
///
/// The base fields (avgCandleSize, avgVolume, prevClose) are used by the
/// dominance strategy. The optional daily-derived fields are populated only
/// for strategies that need them (e.g. Gap Fade needs daily ATR/SMA/prevLow
/// and volume baselines). They default to null so dominance is unaffected.
class CandleStatsModel {
  final int securityId;
  final String symbol;
  final double avgCandleSize; // mean of (high - low)
  final double avgVolume; // mean volume across all 5-min candles
  final double prevClose; // most recent candle's close
  final int totalCandles; // number of candles used

  // ── Daily-derived metrics (Gap Fade and other daily-aware strategies) ──
  /// Wilder's ATR(period) on daily candles.
  final double? dailyAtr;
  /// SMA(period) of daily closes (trend filter).
  final double? dailySma;
  /// Prior trading day's daily LOW (partial-gap check anchor).
  final double? prevDayLow;
  /// 20-day average daily volume (liquidity floor).
  final double? avgDailyVolume;
  /// Average volume of the 09:15 IST opening 5-min bar over the last N days
  /// (quiet-open catalyst baseline).
  final double? avgOpeningBarVolume;

  const CandleStatsModel({
    required this.securityId,
    required this.symbol,
    required this.avgCandleSize,
    required this.avgVolume,
    required this.prevClose,
    required this.totalCandles,
    this.dailyAtr,
    this.dailySma,
    this.prevDayLow,
    this.avgDailyVolume,
    this.avgOpeningBarVolume,
  });

  CandleStatsModel copyWith({
    double? dailyAtr,
    double? dailySma,
    double? prevDayLow,
    double? avgDailyVolume,
    double? avgOpeningBarVolume,
    double? prevClose,
  }) =>
      CandleStatsModel(
        securityId: securityId,
        symbol: symbol,
        avgCandleSize: avgCandleSize,
        avgVolume: avgVolume,
        prevClose: prevClose ?? this.prevClose,
        totalCandles: totalCandles,
        dailyAtr: dailyAtr ?? this.dailyAtr,
        dailySma: dailySma ?? this.dailySma,
        prevDayLow: prevDayLow ?? this.prevDayLow,
        avgDailyVolume: avgDailyVolume ?? this.avgDailyVolume,
        avgOpeningBarVolume: avgOpeningBarVolume ?? this.avgOpeningBarVolume,
      );
}

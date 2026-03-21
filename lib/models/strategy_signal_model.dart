enum SignalType { dominanceCandle, breakout, expired }

class StrategySignalModel {
  final String id;
  final String strategyConfigId;
  final int securityId;
  final String symbol;
  final SignalType type;
  final DateTime timestamp;
  final double entryPrice; // dominance high
  final double stopLoss; // dominance low
  final DateTime expiryTime; // next candle fetch time

  // Dominance candle OHLCV for display
  final double candleOpen;
  final double candleHigh;
  final double candleLow;
  final double candleClose;
  final double candleVolume;

  // Metrics for display
  final double bodyPercent;
  final double upperWickPercent;
  final double lowerWickPercent;
  final double sizeMultiplier;
  final double volumeMultiplier;

  final String reason;

  const StrategySignalModel({
    required this.id,
    required this.strategyConfigId,
    required this.securityId,
    required this.symbol,
    required this.type,
    required this.timestamp,
    required this.entryPrice,
    required this.stopLoss,
    required this.expiryTime,
    required this.candleOpen,
    required this.candleHigh,
    required this.candleLow,
    required this.candleClose,
    required this.candleVolume,
    this.bodyPercent = 0,
    this.upperWickPercent = 0,
    this.lowerWickPercent = 0,
    this.sizeMultiplier = 0,
    this.volumeMultiplier = 0,
    this.reason = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'strategyConfigId': strategyConfigId,
        'securityId': securityId,
        'symbol': symbol,
        'type': type.name,
        'timestamp': timestamp.toIso8601String(),
        'entryPrice': entryPrice,
        'stopLoss': stopLoss,
        'expiryTime': expiryTime.toIso8601String(),
        'candleOpen': candleOpen,
        'candleHigh': candleHigh,
        'candleLow': candleLow,
        'candleClose': candleClose,
        'candleVolume': candleVolume,
        'bodyPercent': bodyPercent,
        'upperWickPercent': upperWickPercent,
        'lowerWickPercent': lowerWickPercent,
        'sizeMultiplier': sizeMultiplier,
        'volumeMultiplier': volumeMultiplier,
        'reason': reason,
      };

  factory StrategySignalModel.fromJson(Map<String, dynamic> json) =>
      StrategySignalModel(
        id: json['id'] as String,
        strategyConfigId: json['strategyConfigId'] as String,
        securityId: json['securityId'] as int,
        symbol: json['symbol'] as String,
        type: SignalType.values.firstWhere((e) => e.name == json['type']),
        timestamp: DateTime.parse(json['timestamp'] as String),
        entryPrice: (json['entryPrice'] as num).toDouble(),
        stopLoss: (json['stopLoss'] as num).toDouble(),
        expiryTime: DateTime.parse(json['expiryTime'] as String),
        candleOpen: (json['candleOpen'] as num).toDouble(),
        candleHigh: (json['candleHigh'] as num).toDouble(),
        candleLow: (json['candleLow'] as num).toDouble(),
        candleClose: (json['candleClose'] as num).toDouble(),
        candleVolume: (json['candleVolume'] as num).toDouble(),
        bodyPercent: (json['bodyPercent'] as num?)?.toDouble() ?? 0,
        upperWickPercent: (json['upperWickPercent'] as num?)?.toDouble() ?? 0,
        lowerWickPercent: (json['lowerWickPercent'] as num?)?.toDouble() ?? 0,
        sizeMultiplier: (json['sizeMultiplier'] as num?)?.toDouble() ?? 0,
        volumeMultiplier: (json['volumeMultiplier'] as num?)?.toDouble() ?? 0,
        reason: json['reason'] as String? ?? '',
      );
}

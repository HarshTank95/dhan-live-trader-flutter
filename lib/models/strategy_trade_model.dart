enum TradeStatus { pending, open, closed, cancelled }

enum TradeOutcome { target, stopLoss, manual, endOfDay, none }

class StrategyTradeModel {
  final String id;
  final String strategyConfigId;
  final String signalId;
  final int securityId;
  final String symbol;
  TradeStatus status;
  final bool isPaperTrade;

  // Entry
  final double entryPrice;
  final int quantity;
  DateTime? entryTime;
  String? dhanOrderId; // null for paper trades

  // Exit
  double? exitPrice;
  DateTime? exitTime;
  TradeOutcome outcome;

  // Targets (from position sizing)
  final double stopLoss;
  final double target;

  StrategyTradeModel({
    required this.id,
    required this.strategyConfigId,
    required this.signalId,
    required this.securityId,
    required this.symbol,
    this.status = TradeStatus.pending,
    required this.isPaperTrade,
    required this.entryPrice,
    required this.quantity,
    this.entryTime,
    this.dhanOrderId,
    this.exitPrice,
    this.exitTime,
    this.outcome = TradeOutcome.none,
    required this.stopLoss,
    required this.target,
  });

  // Computed
  double get pnl {
    final exit = exitPrice ?? 0;
    if (status == TradeStatus.closed && exit > 0) {
      return (exit - entryPrice) * quantity;
    }
    return 0;
  }

  double get pnlPercent {
    if (entryPrice <= 0) return 0;
    final exit = exitPrice ?? 0;
    if (status == TradeStatus.closed && exit > 0) {
      return ((exit - entryPrice) / entryPrice) * 100;
    }
    return 0;
  }

  double get riskAmount => (entryPrice - stopLoss) * quantity;
  double get rewardAmount => (target - entryPrice) * quantity;

  Map<String, dynamic> toJson() => {
        'id': id,
        'strategyConfigId': strategyConfigId,
        'signalId': signalId,
        'securityId': securityId,
        'symbol': symbol,
        'status': status.name,
        'isPaperTrade': isPaperTrade,
        'entryPrice': entryPrice,
        'quantity': quantity,
        'entryTime': entryTime?.toIso8601String(),
        'dhanOrderId': dhanOrderId,
        'exitPrice': exitPrice,
        'exitTime': exitTime?.toIso8601String(),
        'outcome': outcome.name,
        'stopLoss': stopLoss,
        'target': target,
      };

  factory StrategyTradeModel.fromJson(Map<String, dynamic> json) =>
      StrategyTradeModel(
        id: json['id'] as String,
        strategyConfigId: json['strategyConfigId'] as String,
        signalId: json['signalId'] as String,
        securityId: json['securityId'] as int,
        symbol: json['symbol'] as String,
        status:
            TradeStatus.values.firstWhere((e) => e.name == json['status']),
        isPaperTrade: json['isPaperTrade'] as bool,
        entryPrice: (json['entryPrice'] as num).toDouble(),
        quantity: json['quantity'] as int,
        entryTime: json['entryTime'] != null
            ? DateTime.parse(json['entryTime'] as String)
            : null,
        dhanOrderId: json['dhanOrderId'] as String?,
        exitPrice: json['exitPrice'] != null
            ? (json['exitPrice'] as num).toDouble()
            : null,
        exitTime: json['exitTime'] != null
            ? DateTime.parse(json['exitTime'] as String)
            : null,
        outcome:
            TradeOutcome.values.firstWhere((e) => e.name == json['outcome']),
        stopLoss: (json['stopLoss'] as num).toDouble(),
        target: (json['target'] as num).toDouble(),
      );
}

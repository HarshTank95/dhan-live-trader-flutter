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

  /// Round-trip transaction cost as % of leg notional (brokerage + STT +
  /// exchange + GST + stamp + slippage). 0 = gross P&L (dominance default).
  /// Gap Fade sets 0.10% to match the C# net-of-cost benchmark.
  final double costModelPct;

  /// Short-sell direction (sell to open, buy to cover). Only the ORB backtest
  /// sets this today; every long-only strategy leaves the default false, so
  /// existing trades/configs (which have no such key) deserialize unchanged.
  /// The live order path still places BUY only — shorts stay backtest/paper
  /// until Phase 2 wires a SELL entry leg.
  final bool isShort;

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
    this.costModelPct = 0,
    this.isShort = false,
  });

  /// +1 for longs, −1 for shorts — flips the sign of every price-move getter.
  int get _dir => isShort ? -1 : 1;

  // Computed
  double get pnl {
    final exit = exitPrice ?? 0;
    if (status == TradeStatus.closed && exit > 0) {
      final gross = (exit - entryPrice) * quantity * _dir;
      // Cost on both legs: (entry + exit) × qty × pct / 200 (pct is round-trip).
      final cost = (entryPrice + exit) * quantity * costModelPct / 200.0;
      return gross - cost;
    }
    return 0;
  }

  double get pnlPercent {
    if (entryPrice <= 0) return 0;
    final exit = exitPrice ?? 0;
    if (status == TradeStatus.closed && exit > 0) {
      return ((exit - entryPrice) / entryPrice) * 100 * _dir;
    }
    return 0;
  }

  double get riskAmount => (entryPrice - stopLoss) * quantity * _dir;
  double get rewardAmount => (target - entryPrice) * quantity * _dir;

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
        'costModelPct': costModelPct,
        'isShort': isShort,
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
        costModelPct: (json['costModelPct'] as num?)?.toDouble() ?? 0,
        isShort: json['isShort'] as bool? ?? false,
      );
}

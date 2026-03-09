class HoldingModel {
  final String tradingSymbol;
  final int securityId;
  final String exchange;
  final int totalQty;
  final double avgCostPrice;
  double ltp; // updated live by OHLC polling

  HoldingModel({
    required this.tradingSymbol,
    required this.securityId,
    required this.exchange,
    required this.totalQty,
    required this.avgCostPrice,
    required this.ltp,
  });

  factory HoldingModel.fromJson(Map<String, dynamic> json) {
    final avgCost = (json['avgCostPrice'] as num?)?.toDouble() ?? 0.0;
    return HoldingModel(
      tradingSymbol: json['tradingSymbol'] as String? ?? '',
      securityId: int.tryParse(json['securityId'].toString()) ?? 0,
      exchange: json['exchange'] as String? ?? 'NSE',
      totalQty: (json['totalQty'] as num?)?.toInt() ?? 0,
      avgCostPrice: avgCost,
      // Use API's lastTradedPrice if present, else fall back to avgCost
      ltp: (json['lastTradedPrice'] as num?)?.toDouble() ?? avgCost,
    );
  }

  double get invested => totalQty * avgCostPrice;
  double get currentValue => totalQty * ltp;
  double get pnl => currentValue - invested;
  double get pnlPercent => invested > 0 ? (pnl / invested) * 100 : 0;
  bool get isProfit => pnl >= 0;
}

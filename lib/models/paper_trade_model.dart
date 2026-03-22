class PaperTradeModel {
  final String id;
  final int securityId;
  final String symbol;
  final String name;
  final int quantity;
  final double entryPrice;
  final DateTime entryTime;
  final double exitPrice;
  final DateTime exitTime;

  const PaperTradeModel({
    required this.id,
    required this.securityId,
    required this.symbol,
    required this.name,
    required this.quantity,
    required this.entryPrice,
    required this.entryTime,
    required this.exitPrice,
    required this.exitTime,
  });

  double get pnl => (exitPrice - entryPrice) * quantity;
  double get pnlPercent =>
      entryPrice > 0 ? ((exitPrice - entryPrice) / entryPrice) * 100 : 0;
  bool get isProfit => pnl >= 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'securityId': securityId,
        'symbol': symbol,
        'name': name,
        'quantity': quantity,
        'entryPrice': entryPrice,
        'entryTime': entryTime.toIso8601String(),
        'exitPrice': exitPrice,
        'exitTime': exitTime.toIso8601String(),
      };

  factory PaperTradeModel.fromJson(Map<String, dynamic> json) =>
      PaperTradeModel(
        id: json['id'] as String,
        securityId: json['securityId'] as int,
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        quantity: json['quantity'] as int,
        entryPrice: (json['entryPrice'] as num).toDouble(),
        entryTime: DateTime.parse(json['entryTime'] as String),
        exitPrice: (json['exitPrice'] as num).toDouble(),
        exitTime: DateTime.parse(json['exitTime'] as String),
      );
}

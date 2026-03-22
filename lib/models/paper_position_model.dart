class PaperPositionModel {
  final String id;
  final int securityId;
  final String symbol;
  final String name;
  int quantity;
  double entryPrice; // average price if added to
  final DateTime entryTime;
  double ltp; // mutable, updated live from feed
  final bool isShort; // true = short sell position

  PaperPositionModel({
    required this.id,
    required this.securityId,
    required this.symbol,
    required this.name,
    required this.quantity,
    required this.entryPrice,
    required this.entryTime,
    this.ltp = 0,
    this.isShort = false,
  });

  double get invested => quantity * entryPrice;
  double get currentValue => quantity * (ltp > 0 ? ltp : entryPrice);
  double get pnl {
    if (ltp <= 0) return 0;
    return isShort
        ? (entryPrice - ltp) * quantity // short: profit when price drops
        : (ltp - entryPrice) * quantity; // long: profit when price rises
  }
  double get pnlPercent => entryPrice > 0 && ltp > 0
      ? (pnl / (entryPrice * quantity)) * 100
      : 0;
  bool get isProfit => pnl >= 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'securityId': securityId,
        'symbol': symbol,
        'name': name,
        'quantity': quantity,
        'entryPrice': entryPrice,
        'entryTime': entryTime.toIso8601String(),
        'isShort': isShort,
      };

  factory PaperPositionModel.fromJson(Map<String, dynamic> json) =>
      PaperPositionModel(
        id: json['id'] as String,
        securityId: json['securityId'] as int,
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        quantity: json['quantity'] as int,
        entryPrice: (json['entryPrice'] as num).toDouble(),
        entryTime: DateTime.parse(json['entryTime'] as String),
        isShort: json['isShort'] as bool? ?? false,
      );
}

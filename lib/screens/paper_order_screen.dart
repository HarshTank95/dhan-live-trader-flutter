import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dhan_feed_service.dart';
import '../services/paper_trading_service.dart';
import '../widgets/swipe_confirm_widget.dart';

/// Show the paper order bottom sheet. Returns true if order was placed.
Future<bool?> showPaperOrderSheet({
  required BuildContext context,
  required bool isBuy,
  required int securityId,
  required String symbol,
  required String name,
  required double ltp,
  required double prevClose,
  required String clientId,
  required String accessToken,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PaperOrderSheet(
      isBuy: isBuy,
      securityId: securityId,
      symbol: symbol,
      name: name,
      ltp: ltp,
      prevClose: prevClose,
      clientId: clientId,
      accessToken: accessToken,
    ),
  );
}

class _PaperOrderSheet extends StatefulWidget {
  final bool isBuy;
  final int securityId;
  final String symbol;
  final String name;
  final double ltp;
  final double prevClose;
  final String clientId;
  final String accessToken;

  const _PaperOrderSheet({
    required this.isBuy,
    required this.securityId,
    required this.symbol,
    required this.name,
    required this.ltp,
    required this.prevClose,
    required this.clientId,
    required this.accessToken,
  });

  @override
  State<_PaperOrderSheet> createState() => _PaperOrderSheetState();
}

class _PaperOrderSheetState extends State<_PaperOrderSheet> {
  final _paperService = PaperTradingService();

  // Live price
  DhanFeedService? _feedService;
  StreamSubscription<Map<int, FeedUpdate>>? _feedSub;
  double _ltp = 0;
  double _prevClose = 0;

  // Order config
  String _orderType = 'Market';
  int _quantity = 1;
  double _limitPrice = 0;
  final _qtyController = TextEditingController(text: '1');
  final _priceController = TextEditingController();

  bool _executing = false;

  // Colors
  Color get _accent =>
      widget.isBuy ? const Color(0xFF4CAF50) : const Color(0xFFE53935);
  Color get _accentBg =>
      widget.isBuy ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE);

  @override
  void initState() {
    super.initState();
    _ltp = widget.ltp;
    _prevClose = widget.prevClose;
    _limitPrice = widget.ltp;
    _priceController.text = widget.ltp.toStringAsFixed(2);

    _connectFeed();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _priceController.dispose();
    _feedSub?.cancel();
    _feedService?.disconnect();
    super.dispose();
  }

  void _connectFeed() {
    _feedService = DhanFeedService(
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    );
    _feedSub = _feedService!.dataStream.listen((data) {
      final update = data[widget.securityId];
      if (update != null && mounted) {
        setState(() {
          if (update.ltp > 0) _ltp = update.ltp;
          if (update.prevClose > 0) _prevClose = update.prevClose;
        });
      }
    });
    _feedService!.connect([widget.securityId]);
  }

  double get _execPrice => _orderType == 'Market' ? _ltp : _limitPrice;

  // ── Order execution ──────────────────────────────────────────────

  Future<void> _executeBuy() async {
    if (_executing) return;
    _executing = true;

    final position = _paperService.positionFor(widget.securityId);

    String? err;
    if (position != null && position.isShort) {
      // Covering a short position
      if (_quantity == position.quantity) {
        err = await _paperService.closePosition(position.id, _execPrice);
      } else if (_quantity < position.quantity) {
        err = await _paperService.sellPartial(
          positionId: position.id,
          quantity: _quantity,
          ltp: _execPrice,
        );
      } else {
        err = 'Quantity exceeds short position (${position.quantity})';
      }
      if (!mounted) return;
      if (err != null) {
        _executing = false;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
        return;
      }
      final pnl = (position.entryPrice - _execPrice) * _quantity;
      final pnlSign = pnl >= 0 ? '+' : '';
      _onSuccess(
        '${widget.symbol} Short covered | $_quantity x ₹${_execPrice.toStringAsFixed(2)}  P&L: $pnlSign₹${pnl.abs().toStringAsFixed(2)}',
      );
      return;
    }

    // Normal buy
    err = await _paperService.buyStock(
      securityId: widget.securityId,
      symbol: widget.symbol,
      name: widget.name,
      quantity: _quantity,
      ltp: _execPrice,
    );
    if (!mounted) return;
    if (err != null) {
      _executing = false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
      return;
    }
    _onSuccess('${widget.symbol} Buy order placed | $_quantity x ₹${_execPrice.toStringAsFixed(2)}');
  }

  Future<void> _executeSell() async {
    if (_executing) return;
    _executing = true;
    final position = _paperService.positionFor(widget.securityId);

    String? err;
    if (position == null || position.isShort) {
      // No position or existing short → short sell
      err = await _paperService.sellShort(
        securityId: widget.securityId,
        symbol: widget.symbol,
        name: widget.name,
        quantity: _quantity,
        ltp: _execPrice,
      );
      if (!mounted) return;
      if (err != null) {
        _executing = false;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
        return;
      }
      _onSuccess('${widget.symbol} Short sell order placed | $_quantity x ₹${_execPrice.toStringAsFixed(2)}');
      return;
    }

    // Has long position → close/partial sell
    if (_quantity == position.quantity) {
      err = await _paperService.closePosition(position.id, _execPrice);
    } else if (_quantity < position.quantity) {
      err = await _paperService.sellPartial(
        positionId: position.id,
        quantity: _quantity,
        ltp: _execPrice,
      );
    } else {
      err = 'Quantity exceeds holding (${position.quantity})';
    }
    if (!mounted) return;
    if (err != null) {
      _executing = false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
      return;
    }
    final pnl = (_execPrice - position.entryPrice) * _quantity;
    final pnlSign = pnl >= 0 ? '+' : '';
    _onSuccess(
      '${widget.symbol} Sell order executed | $_quantity x ₹${_execPrice.toStringAsFixed(2)}  P&L: $pnlSign₹${pnl.abs().toStringAsFixed(2)}',
    );
  }

  void _onSuccess(String message) {
    HapticFeedback.heavyImpact();
    Navigator.pop(context, true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: _accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  void _setQuantity(int qty) {
    if (qty < 1) qty = 1;
    if (!widget.isBuy) {
      final position = _paperService.positionFor(widget.securityId);
      if (position != null && qty > position.quantity) qty = position.quantity;
    }
    setState(() {
      _quantity = qty;
      _qtyController.text = '$qty';
      _qtyController.selection = TextSelection.fromPosition(
        TextPosition(offset: _qtyController.text.length),
      );
    });
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    final position = _paperService.positionFor(widget.securityId);
    final cost = _quantity * _execPrice;
    final available = _paperService.availableBalance;
    final bool canTrade;
    if (widget.isBuy) {
      canTrade = cost <= available && _quantity > 0;
    } else if (position != null && !position.isShort) {
      // Selling long position — qty must not exceed holding
      canTrade = _quantity > 0 && _quantity <= position.quantity;
    } else {
      // Short sell — needs margin
      canTrade = cost <= available && _quantity > 0;
    }

    final change = _prevClose > 0 ? _ltp - _prevClose : 0.0;
    final changePct = _prevClose > 0 ? (change / _prevClose) * 100 : 0.0;
    final changeColor = change >= 0 ? Colors.green : Colors.red;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ────────────────────────────────────────
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Header: symbol + LTP + BUY/SELL ────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(widget.symbol,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.grey.shade800
                                  : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text('NSE',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.grey.shade600,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text('₹${_ltp.toStringAsFixed(2)}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          Text(
                            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} (${changePct.toStringAsFixed(2)}%)',
                            style: TextStyle(
                                fontSize: 12,
                                color: changeColor,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.grey.shade800
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('PAPER',
                      style: TextStyle(
                          fontSize: 9,
                          color: Colors.orange,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),

          Divider(height: 1, color: Colors.grey.withValues(alpha: 0.15)),

          // ── Product type ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.15)
                          : Colors.blue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    'Intraday',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.blue.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Qty + Price row ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                // Qty
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Qty',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                      const SizedBox(height: 6),
                      _buildQtyField(isDark, position),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Price
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Price',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                      const SizedBox(height: 6),
                      _buildPriceField(isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Order type ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                _toggleChip('Market', _orderType == 'Market', isDark, () {
                  setState(() => _orderType = 'Market');
                }, isBlue: true),
                const SizedBox(width: 8),
                _toggleChip('Limit', _orderType == 'Limit', isDark, () {
                  setState(() {
                    _orderType = 'Limit';
                    _limitPrice = _ltp;
                    _priceController.text = _ltp.toStringAsFixed(2);
                  });
                }, isBlue: true),
              ],
            ),
          ),

          // ── Margin / position info ─────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: widget.isBuy
                ? _buildBuyInfo(cost, available)
                : _buildSellInfo(position),
          ),

          Divider(height: 1, color: Colors.grey.withValues(alpha: 0.12)),

          // ── Swipe to confirm ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: canTrade
                ? SwipeConfirmWidget(
                    text: widget.isBuy ? 'Swipe to Buy' : 'Swipe to Sell',
                    color: _accent,
                    onConfirmed: widget.isBuy ? _executeBuy : _executeSell,
                    height: 50,
                  )
                : Container(
                    height: 50,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(25),
                      color: Colors.grey.withValues(alpha: 0.12),
                    ),
                    child: Center(
                      child: Text(
                        widget.isBuy ? 'Insufficient funds' : 'Enter valid quantity',
                        style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
          ),

          // Bottom safe area
          SizedBox(height: MediaQuery.of(context).padding.bottom + 4),
        ],
      ),
    );
  }

  // ── Reusable toggle chip ───────────────────────────────────────────

  Widget _toggleChip(
      String label, bool selected, bool isDark, VoidCallback onTap,
      {bool isBlue = false}) {
    final activeColor = isBlue ? Colors.blue : _accent;
    final activeBg = isBlue
        ? (isDark
            ? Colors.blue.shade900.withValues(alpha: 0.3)
            : Colors.blue.shade50)
        : _accentBg;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? activeBg
              : (isDark ? Colors.grey.shade900 : Colors.grey.shade100),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? activeColor.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? activeColor : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // ── Quantity field ─────────────────────────────────────────────────

  Widget _buildQtyField(bool isDark, dynamic position) {
    final maxQty = !widget.isBuy ? (position?.quantity ?? 0) : 99999;

    return Container(
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
      ),
      child: Row(
        children: [
          _fieldButton(Icons.remove, isDark, () {
            HapticFeedback.selectionClick();
            _setQuantity(_quantity - 1);
          }, isLeft: true),
          Expanded(
            child: TextField(
              controller: _qtyController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (val) {
                final qty = int.tryParse(val) ?? 0;
                if (qty > 0) {
                  setState(() => _quantity = qty > maxQty ? maxQty : qty);
                }
              },
            ),
          ),
          _fieldButton(Icons.add, isDark, () {
            HapticFeedback.selectionClick();
            _setQuantity(_quantity + 1);
          }, isLeft: false),
        ],
      ),
    );
  }

  // ── Price field ───────────────────────────────────────────────────

  Widget _buildPriceField(bool isDark) {
    if (_orderType == 'Market') {
      return Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
          color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
        ),
        child: Text(
          '₹${_ltp.toStringAsFixed(2)}',
          style: TextStyle(
              fontSize: 15,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500),
        ),
      );
    }

    // Limit order — simple editable text box
    return Container(
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
      ),
      child: TextField(
        controller: _priceController,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 12),
        ),
        onChanged: (val) {
          final price = double.tryParse(val);
          if (price != null && price > 0) {
            setState(() => _limitPrice = price);
          }
        },
      ),
    );
  }

  Widget _fieldButton(
      IconData icon, bool isDark, VoidCallback onTap,
      {required bool isLeft}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            left: isLeft
                ? BorderSide.none
                : BorderSide(
                    color:
                        isDark ? Colors.grey.shade700 : Colors.grey.shade300),
            right: isLeft
                ? BorderSide(
                    color:
                        isDark ? Colors.grey.shade700 : Colors.grey.shade300)
                : BorderSide.none,
          ),
        ),
        child: Icon(icon, size: 16, color: Colors.grey.shade600),
      ),
    );
  }

  // ── Buy info ──────────────────────────────────────────────────────

  Widget _buildBuyInfo(double cost, double available) {
    final sufficient = cost <= available;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Margin required',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 2),
            Text('₹${_fmtIndian(cost)}',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: sufficient ? null : Colors.red)),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Available margin',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 2),
            Text('₹${_fmtIndian(available)}',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ],
    );
  }

  // ── Sell info ─────────────────────────────────────────────────────

  Widget _buildSellInfo(dynamic position) {
    if (position == null || position.isShort) {
      // Short sell — show margin info like buy
      final margin = _quantity * _execPrice;
      final available = _paperService.availableBalance;
      final sufficient = margin <= available;
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Margin required',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(height: 2),
              Text('₹${_fmtIndian(margin)}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: sufficient ? null : Colors.red)),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('Available margin',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(height: 2),
              Text('₹${_fmtIndian(available)}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      );
    }

    // Closing long position
    final pnl = (_execPrice - position.entryPrice) * _quantity;
    final pnlColor = pnl >= 0 ? Colors.green : Colors.red;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Holding',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 2),
            Text(
                '${position.quantity} qty @ ₹${position.entryPrice.toStringAsFixed(2)}',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Est. P&L',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 2),
            Text(
              '${pnl >= 0 ? '+' : ''}₹${pnl.abs().toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: pnlColor),
            ),
          ],
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────

  String _fmtIndian(double val) {
    if (val < 0) return '-${_fmtIndian(val.abs())}';
    final intPart = val.truncate();
    final decPart = ((val - intPart) * 100).round().toString().padLeft(2, '0');
    final str = intPart.toString();
    if (str.length <= 3) return '$str.$decPart';

    final last3 = str.substring(str.length - 3);
    var rest = str.substring(0, str.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    groups.add(last3);
    return '${groups.join(',')}.$decPart';
  }
}


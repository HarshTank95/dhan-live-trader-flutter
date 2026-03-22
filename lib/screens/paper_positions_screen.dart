import 'dart:async';
import 'package:flutter/material.dart';
import '../models/paper_position_model.dart';
import '../models/paper_trade_model.dart';
import '../services/dhan_feed_service.dart';
import '../services/paper_trading_service.dart';
import 'paper_order_screen.dart';

class PaperPositionsScreen extends StatefulWidget {
  final String clientId;
  final String accessToken;

  const PaperPositionsScreen({
    super.key,
    required this.clientId,
    required this.accessToken,
  });

  @override
  State<PaperPositionsScreen> createState() => _PaperPositionsScreenState();
}

class _PaperPositionsScreenState extends State<PaperPositionsScreen>
    with SingleTickerProviderStateMixin {
  final _paperService = PaperTradingService();
  DhanFeedService? _feedService;
  StreamSubscription<Map<int, FeedUpdate>>? _feedSub;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _connectFeed();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _feedSub?.cancel();
    _feedService?.disconnect();
    super.dispose();
  }

  void _connectFeed() {
    final ids = _paperService.positionSecurityIds.toList();
    if (ids.isEmpty) return;
    _feedService = DhanFeedService(
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    );
    _feedSub = _feedService!.dataStream.listen((data) {
      final ltpMap = <int, double>{};
      for (final entry in data.entries) {
        if (entry.value.ltp > 0) ltpMap[entry.key] = entry.value.ltp;
      }
      _paperService.updateLtp(ltpMap);
      if (mounted) setState(() {});
    });
    _feedService!.connect(ids);
  }

  void _reconnectFeed() {
    _feedSub?.cancel();
    _feedService?.disconnect();
    _feedService = null;
    _connectFeed();
  }

  void _openCloseScreen(PaperPositionModel position) {
    final ltp = position.ltp > 0 ? position.ltp : position.entryPrice;
    showPaperOrderSheet(
      context: context,
      isBuy: position.isShort,
      securityId: position.securityId,
      symbol: position.symbol,
      name: position.name,
      ltp: ltp,
      prevClose: position.entryPrice,
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    ).then((placed) {
      if (placed == true && mounted) {
        _reconnectFeed();
        setState(() {});
      }
    });
  }

  Future<void> _resetPortfolio() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reset Portfolio'),
        content: const Text(
            'Close all positions, clear history, and reset balance to ₹10,00,000.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _paperService.resetPortfolio();
    _reconnectFeed();
    if (mounted) setState(() {});
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF121212) : const Color(0xFFF5F6FA);
    final surfaceColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final subtleText = isDark ? Colors.grey.shade500 : Colors.grey.shade600;

    final unrealisedPnl = _paperService.unrealisedPnl;
    final realisedPnl = _paperService.realisedPnl;

    return Scaffold(
      backgroundColor: bg,
      body: Column(
        children: [
          // ── Clean Header ─────────────────────────────────────────
          Container(
            color: surfaceColor,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // App bar
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, size: 22),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const Expanded(
                          child: Text('Paper Trading',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          icon: Icon(Icons.restart_alt_rounded,
                              size: 22, color: subtleText),
                          tooltip: 'Reset Portfolio',
                          onPressed: _resetPortfolio,
                        ),
                      ],
                    ),
                  ),

                  // Balance + stats
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text('Available Balance',
                            style: TextStyle(
                                fontSize: 12,
                                color: subtleText,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        Text('₹${_fmtIndian(_paperService.availableBalance)}',
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5)),
                        const SizedBox(height: 16),
                        // Stats row
                        Row(
                          children: [
                            _statItem('Invested', _paperService.usedMargin, subtleText, isDark),
                            _vertDivider(isDark),
                            _pnlStatItem('Unrealised', unrealisedPnl, subtleText),
                            _vertDivider(isDark),
                            _pnlStatItem('Realised', realisedPnl, subtleText),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Tab bar
                  TabBar(
                    controller: _tabController,
                    indicatorColor: isDark ? Colors.white : Colors.black87,
                    indicatorWeight: 2.5,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelColor: isDark ? Colors.white : Colors.black87,
                    unselectedLabelColor: subtleText,
                    labelStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    unselectedLabelStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                    tabs: [
                      Tab(text: 'Positions (${_paperService.positions.length})'),
                      Tab(text: 'History (${_paperService.tradeHistory.length})'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Thin separator
          Container(
            height: 1,
            color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
          ),

          // ── Body ────────────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildPositions(isDark, surfaceColor, subtleText),
                _buildHistory(isDark, surfaceColor, subtleText),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String label, double value, Color subtleText, bool isDark) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: subtleText)),
          const SizedBox(height: 3),
          Text('₹${_fmtCompact(value)}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87)),
        ],
      ),
    );
  }

  Widget _pnlStatItem(String label, double value, Color subtleText) {
    final isProfit = value >= 0;
    final color = isProfit ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    final sign = isProfit ? '+' : '';

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: subtleText)),
          const SizedBox(height: 3),
          Text('$sign₹${_fmtCompact(value.abs())}',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _vertDivider(bool isDark) {
    return Container(
      width: 1,
      height: 28,
      color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
    );
  }

  // ── Positions Tab ─────────────────────────────────────────────────

  Widget _buildPositions(bool isDark, Color surfaceColor, Color subtleText) {
    final positions = List<PaperPositionModel>.from(_paperService.positions)
      ..sort((a, b) => b.pnl.compareTo(a.pnl));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // Day P&L card
        _buildDayPnlCard(isDark, surfaceColor, subtleText),
        const SizedBox(height: 8),

        if (positions.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Column(
              children: [
                Icon(Icons.inbox_rounded,
                    size: 48, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text('No open positions',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.grey.shade400 : Colors.grey.shade700)),
                const SizedBox(height: 4),
                Text('Buy stocks from the watchlist to start trading',
                    style: TextStyle(color: subtleText, fontSize: 12)),
              ],
            ),
          )
        else
          ...positions.map((p) => _positionCard(p, isDark, surfaceColor, subtleText)),
      ],
    );
  }

  Widget _buildDayPnlCard(bool isDark, Color surfaceColor, Color subtleText) {
    final todayPnl = _paperService.todayRealisedPnl;
    final tradeCount = _paperService.todayTradeCount;
    final winCount = _paperService.todayWinCount;
    final lossCount = tradeCount - winCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Today's Realised",
                    style: TextStyle(
                        fontSize: 11,
                        color: subtleText,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(
                  '${todayPnl >= 0 ? '+' : ''}₹${_fmtIndian(todayPnl.abs())}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: todayPnl >= 0
                        ? const Color(0xFF16A34A)
                        : const Color(0xFFDC2626),
                  ),
                ),
              ],
            ),
          ),
          if (tradeCount > 0)
            Row(
              children: [
                _miniChip('$winCount W', const Color(0xFF16A34A)),
                const SizedBox(width: 6),
                _miniChip('$lossCount L', const Color(0xFFDC2626)),
                const SizedBox(width: 10),
                Text('$tradeCount trades',
                    style: TextStyle(fontSize: 11, color: subtleText)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _miniChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _positionCard(PaperPositionModel p, bool isDark, Color surfaceColor, Color subtleText) {
    final isProfit = p.isProfit;
    final pnlColor = isProfit ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    final actionColor = p.isShort ? const Color(0xFF2563EB) : const Color(0xFFDC2626);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            // Row 1: Symbol + LTP
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(p.symbol,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      if (p.isShort) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('SHORT',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3)),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text('${p.quantity} qty',
                          style: TextStyle(
                              fontSize: 11, color: subtleText)),
                    ],
                  ),
                ),
                // P&L
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${isProfit ? '+' : ''}₹${p.pnl.abs().toStringAsFixed(2)}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: pnlColor),
                    ),
                    Text('${isProfit ? '+' : ''}${p.pnlPercent.toStringAsFixed(2)}%',
                        style: TextStyle(
                            fontSize: 11,
                            color: pnlColor,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Row 2: Avg + LTP + action button
            Row(
              children: [
                Text('Avg ₹${p.entryPrice.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 11, color: subtleText)),
                const SizedBox(width: 16),
                Text('LTP ',
                    style: TextStyle(fontSize: 11, color: subtleText)),
                Text(
                  p.ltp > 0 ? '₹${p.ltp.toStringAsFixed(2)}' : '—',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87),
                ),
                const Spacer(),
                SizedBox(
                  height: 30,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: actionColor,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(color: actionColor.withValues(alpha: 0.4)),
                      ),
                    ),
                    onPressed: () => _openCloseScreen(p),
                    child: Text(p.isShort ? 'COVER' : 'EXIT',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── History Tab ───────────────────────────────────────────────────

  Widget _buildHistory(bool isDark, Color surfaceColor, Color subtleText) {
    final trades = _paperService.tradeHistory;
    if (trades.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_rounded,
                size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No trade history',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade700)),
            const SizedBox(height: 4),
            Text('Closed trades will appear here',
                style: TextStyle(color: subtleText, fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: trades.length,
      itemBuilder: (context, index) =>
          _tradeCard(trades[index], isDark, surfaceColor, subtleText),
    );
  }

  Widget _tradeCard(PaperTradeModel t, bool isDark, Color surfaceColor, Color subtleText) {
    final isProfit = t.isProfit;
    final pnlColor = isProfit ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    final sign = isProfit ? '+' : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Profit/Loss indicator dot
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: pnlColor,
              ),
            ),
            // Left: symbol + details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(t.symbol,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      Text('${t.quantity} qty',
                          style: TextStyle(fontSize: 11, color: subtleText)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '₹${t.entryPrice.toStringAsFixed(2)} → ₹${t.exitPrice.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 11, color: subtleText),
                  ),
                ],
              ),
            ),
            // Right: P&L + time
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$sign₹${t.pnl.abs().toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: pnlColor),
                ),
                const SizedBox(height: 2),
                Text(
                  _fmtDateTime(t.exitTime),
                  style: TextStyle(fontSize: 10, color: subtleText),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────

  String _fmtIndian(double val) {
    final isNeg = val < 0;
    final abs = val.abs();
    final parts = abs.toStringAsFixed(2).split('.');
    final whole = parts[0];
    final dec = parts[1];

    if (whole.length <= 3) return '${isNeg ? '-' : ''}$whole.$dec';

    final last3 = whole.substring(whole.length - 3);
    var remaining = whole.substring(0, whole.length - 3);
    final groups = <String>[];
    while (remaining.length > 2) {
      groups.insert(0, remaining.substring(remaining.length - 2));
      remaining = remaining.substring(0, remaining.length - 2);
    }
    if (remaining.isNotEmpty) groups.insert(0, remaining);

    return '${isNeg ? '-' : ''}${groups.join(',')},${last3}.$dec';
  }

  String _fmtCompact(double val) {
    if (val >= 1e7) return '${(val / 1e7).toStringAsFixed(2)} Cr';
    if (val >= 1e5) return '${(val / 1e5).toStringAsFixed(2)} L';
    if (val >= 1e3) return '${(val / 1e3).toStringAsFixed(1)}K';
    return val.toStringAsFixed(2);
  }

  String _fmtDateTime(DateTime dt) {
    final d = '${dt.day}/${dt.month}/${dt.year}';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$d  $h:$m ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }
}

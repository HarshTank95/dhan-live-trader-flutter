import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Data model emitted by the feed ──────────────────────────────────────────

class FeedUpdate {
  final int securityId;
  final double ltp;
  final double open;
  final double high;
  final double low;
  final double prevClose;
  final int volume;

  const FeedUpdate({
    required this.securityId,
    required this.ltp,
    required this.open,
    required this.high,
    required this.low,
    required this.prevClose,
    required this.volume,
  });

  FeedUpdate copyWith({
    double? ltp,
    double? open,
    double? high,
    double? low,
    double? prevClose,
    int? volume,
  }) =>
      FeedUpdate(
        securityId: securityId,
        ltp: ltp ?? this.ltp,
        open: open ?? this.open,
        high: high ?? this.high,
        low: low ?? this.low,
        prevClose: prevClose ?? this.prevClose,
        volume: volume ?? this.volume,
      );
}

enum FeedStatus { connecting, connected, disconnected }

// ── WebSocket feed service ───────────────────────────────────────────────────
//
// Protocol: wss://api-feed.dhan.co?version=2&token=…&clientId=…&authType=2
// Binary packets, little-endian byte order:
//
//   Header (8 bytes): [code:u8][msgLen:u16][exchange:u8][securityId:i32]
//
//   Code 2 – Ticker  : header + LTP(f32) + tradeTime(i32)          = 16 bytes
//   Code 4 – Quote   : header + LTP(4)+qty(2)+time(4)+avg(4)+
//                      vol(4)+sell(4)+buy(4)+open(4)+close(4)+
//                      high(4)+low(4)                               = 50 bytes
//   Code 6 – PrevClose: header + prevClose(f32) + OI(i32)          = 16 bytes

class DhanFeedService {
  final String clientId;
  final String accessToken;

  DhanFeedService({required this.clientId, required this.accessToken});

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;

  final _dataCtrl = StreamController<Map<int, FeedUpdate>>.broadcast();
  final _statusCtrl = StreamController<FeedStatus>.broadcast();

  final Map<int, FeedUpdate> _data = {};
  List<int> _ids = [];
  bool _disposed = false;
  bool _intentionalClose = false;

  Stream<Map<int, FeedUpdate>> get dataStream => _dataCtrl.stream;
  Stream<FeedStatus> get statusStream => _statusCtrl.stream;

  /// Latest snapshot — useful when resuming from a paused screen.
  Map<int, FeedUpdate> get snapshot => Map.unmodifiable(_data);

  // ── Public API ─────────────────────────────────────────────────────────────

  void connect(List<int> securityIds) {
    _ids = List.from(securityIds);
    _intentionalClose = false;
    _doConnect();
  }

  /// Close current connection and reconnect with a new instrument list.
  void resubscribe(List<int> securityIds) {
    _ids = List.from(securityIds);
    _data.clear();
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _intentionalClose = false;
    _doConnect();
  }

  void disconnect() {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.add(jsonEncode({'RequestCode': 12}));
    } catch (_) {}
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _dataCtrl.close();
    _statusCtrl.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _doConnect() {
    if (_disposed) return;
    _emitStatus(FeedStatus.connecting);
    try {
      final uri = Uri.parse(
        'wss://api-feed.dhan.co?version=2&token=$accessToken'
        '&clientId=$clientId&authType=2',
      );
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _subscribe(_ids);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _subscribe(List<int> ids) {
    if (ids.isEmpty) return;
    for (var i = 0; i < ids.length; i += 100) {
      final batch = ids.sublist(i, (i + 100).clamp(0, ids.length));
      _channel?.sink.add(jsonEncode({
        'RequestCode': 15,
        'InstrumentCount': batch.length,
        'InstrumentList': batch
            .map((id) => {'ExchangeSegment': 'NSE_EQ', 'SecurityId': id.toString()})
            .toList(),
      }));
    }
  }

  void _onData(dynamic msg) {
    if (msg is Uint8List) {
      _parsePacket(msg);
    } else if (msg is List<int>) {
      _parsePacket(Uint8List.fromList(msg));
    }
    // JSON string messages (connection ack, errors) are ignored
  }

  void _parsePacket(Uint8List data) {
    if (data.length < 8) return;
    final bd = ByteData.sublistView(data);
    final code = bd.getUint8(0);
    final secId = bd.getInt32(4, Endian.little);

    switch (code) {
      // ── Ticker packet ────────────────────────────────────────────────────
      case 2:
        if (data.length < 16) return;
        final ltp = bd.getFloat32(8, Endian.little);
        if (ltp <= 0) return;
        _data[secId] = (_data[secId] ?? _empty(secId)).copyWith(ltp: ltp);
        _emitStatus(FeedStatus.connected); // first packet = truly connected
        _emitData();

      // ── Full Quote packet ─────────────────────────────────────────────────
      case 4:
        if (data.length < 50) return;
        final ltp = bd.getFloat32(8, Endian.little);
        final vol = bd.getInt32(22, Endian.little);
        final open = bd.getFloat32(34, Endian.little);
        final closePx = bd.getFloat32(38, Endian.little); // prev day's close
        final high = bd.getFloat32(42, Endian.little);
        final low = bd.getFloat32(46, Endian.little);
        // Use Code 6 prevClose if already received, otherwise use close field
        final existingPrev = _data[secId]?.prevClose ?? 0;
        final prevClose = existingPrev > 0 ? existingPrev : closePx;
        // Preserve existing ltp if packet reports 0 (outside market hours)
        final newLtp = ltp > 0 ? ltp : (_data[secId]?.ltp ?? 0);
        _data[secId] = FeedUpdate(
          securityId: secId,
          ltp: newLtp,
          open: open,
          high: high,
          low: low,
          prevClose: prevClose,
          volume: vol,
        );
        _emitStatus(FeedStatus.connected);
        _emitData();

      // ── Previous-Close packet (sent once on subscription) ─────────────────
      case 6:
        if (data.length < 16) return;
        final prevClose = bd.getFloat32(8, Endian.little);
        if (prevClose <= 0) return;
        _data[secId] = (_data[secId] ?? _empty(secId)).copyWith(prevClose: prevClose);
        _emitStatus(FeedStatus.connected);
        _emitData();
    }
  }

  FeedUpdate _empty(int secId) => FeedUpdate(
        securityId: secId,
        ltp: 0, open: 0, high: 0, low: 0, prevClose: 0, volume: 0,
      );

  void _emitData() {
    if (!_dataCtrl.isClosed) _dataCtrl.add(Map.from(_data));
  }

  void _emitStatus(FeedStatus s) {
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  void _onError(dynamic _) {
    _emitStatus(FeedStatus.disconnected);
    _scheduleReconnect();
  }

  void _onDone() {
    if (_intentionalClose) return;
    _emitStatus(FeedStatus.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionalClose) return;
    _sub?.cancel();
    _channel = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _doConnect);
  }
}

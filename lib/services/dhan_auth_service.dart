import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of a successful access-token generation.
class GeneratedToken {
  final String accessToken;
  final String? clientId;
  final String? clientName;
  final String? expiryTime;

  GeneratedToken({
    required this.accessToken,
    this.clientId,
    this.clientName,
    this.expiryTime,
  });
}

/// Thrown when token generation fails (bad PIN/TOTP, network, etc.).
class DhanTokenGenException implements Exception {
  final String message;
  DhanTokenGenException(this.message);
  @override
  String toString() => message;
}

/// Calls Dhan's auth service to mint a fresh access token directly from
/// Client ID + PIN + TOTP, so the user doesn't have to copy a token from the
/// Dhan web portal. Requires TOTP to be enabled on the account.
///
/// Endpoint: POST https://auth.dhan.co/app/generateAccessToken
/// Parameters are passed as query string (dhanClientId, pin, totp).
class DhanAuthService {
  static const String _url = 'https://auth.dhan.co/app/generateAccessToken';

  static Future<GeneratedToken> generateAccessToken({
    required String clientId,
    required String pin,
    required String totp,
  }) async {
    final uri = Uri.parse(_url).replace(queryParameters: {
      'dhanClientId': clientId,
      'pin': pin,
      'totp': totp,
    });

    http.Response res;
    try {
      res = await http
          .post(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw DhanTokenGenException('Network error: $e');
    }

    Map<String, dynamic>? body;
    try {
      if (res.body.isNotEmpty) {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {
      body = null;
    }

    if (res.statusCode != 200) {
      final msg = _extractError(body) ??
          'Generation failed (HTTP ${res.statusCode}). '
              'Check Client ID, PIN and TOTP.';
      throw DhanTokenGenException(msg);
    }

    final token = body?['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw DhanTokenGenException(
          _extractError(body) ?? 'No access token returned by Dhan.');
    }

    return GeneratedToken(
      accessToken: token,
      clientId: body?['dhanClientId'] as String?,
      clientName: body?['dhanClientName'] as String?,
      expiryTime: body?['expiryTime'] as String?,
    );
  }

  /// Dhan error payloads vary; try the common field names.
  static String? _extractError(Map<String, dynamic>? body) {
    if (body == null) return null;
    for (final key in ['errorMessage', 'message', 'error', 'errorType']) {
      final v = body[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }
}

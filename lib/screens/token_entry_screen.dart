import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ltp_screen.dart';
import '../services/storage_service.dart';
import '../services/dhan_auth_service.dart';

class TokenEntryScreen extends StatefulWidget {
  final String? initialClientId;
  final String? initialAccessToken;

  const TokenEntryScreen({
    super.key,
    this.initialClientId,
    this.initialAccessToken,
  });

  @override
  State<TokenEntryScreen> createState() => _TokenEntryScreenState();
}

enum _AuthMode { paste, generate }

class _TokenEntryScreenState extends State<TokenEntryScreen> {
  late final TextEditingController _clientIdController;
  late final TextEditingController _accessTokenController;
  final _pinController = TextEditingController();
  final _totpController = TextEditingController();

  _AuthMode _mode = _AuthMode.paste;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _clientIdController =
        TextEditingController(text: widget.initialClientId ?? '');
    _accessTokenController =
        TextEditingController(text: widget.initialAccessToken ?? '');
  }

  Future<void> _generate() async {
    final clientId = _clientIdController.text.trim();
    final pin = _pinController.text.trim();
    final totp = _totpController.text.trim();

    if (clientId.isEmpty || pin.isEmpty || totp.isEmpty) {
      _snack('Enter Client ID, PIN and TOTP', isError: true);
      return;
    }

    setState(() => _generating = true);
    try {
      final result = await DhanAuthService.generateAccessToken(
        clientId: clientId,
        pin: pin,
        totp: totp,
      );

      // Fill the token field and persist immediately, then continue.
      _accessTokenController.text = result.accessToken;
      final resolvedClientId = result.clientId?.isNotEmpty == true
          ? result.clientId!
          : clientId;

      await StorageService.saveCredentials(
        clientId: resolvedClientId,
        accessToken: result.accessToken,
      );

      if (!mounted) return;
      _snack(
        'Token generated${result.clientName != null ? " for ${result.clientName}" : ""}',
      );
      _goToLtp(resolvedClientId, result.accessToken);
    } on DhanTokenGenException catch (e) {
      if (mounted) _snack(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _proceed() async {
    final clientId = _clientIdController.text.trim();
    final accessToken = _accessTokenController.text.trim();

    if (clientId.isEmpty || accessToken.isEmpty) {
      _snack('Please enter both Client ID and Access Token', isError: true);
      return;
    }

    await StorageService.saveCredentials(
      clientId: clientId,
      accessToken: accessToken,
    );

    if (!mounted) return;
    _goToLtp(clientId, accessToken);
  }

  void _goToLtp(String clientId, String accessToken) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LtpScreen(clientId: clientId, accessToken: accessToken),
      ),
    );
  }

  void _snack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _accessTokenController.dispose();
    _pinController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialClientId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Credentials' : 'Dhan LTP Viewer'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Icon(Icons.show_chart, size: 64, color: Colors.blue),
            const SizedBox(height: 16),
            Text(
              isEditing ? 'Update Credentials' : 'Enter Dhan Credentials',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Your token is saved locally on this device',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SegmentedButton<_AuthMode>(
              segments: const [
                ButtonSegment(
                  value: _AuthMode.paste,
                  label: Text('Paste token'),
                  icon: Icon(Icons.key_outlined),
                ),
                ButtonSegment(
                  value: _AuthMode.generate,
                  label: Text('Generate token'),
                  icon: Icon(Icons.bolt_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _generating
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _clientIdController,
              decoration: const InputDecoration(
                labelText: 'Client ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 16),
            if (_mode == _AuthMode.paste)
              ..._buildPasteFields()
            else
              ..._buildGenerateFields(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPasteFields() {
    final isEditing = widget.initialClientId != null;
    return [
      TextField(
        controller: _accessTokenController,
        decoration: const InputDecoration(
          labelText: 'Access Token',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.key_outlined),
          alignLabelWithHint: true,
        ),
        maxLines: 4,
      ),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: _proceed,
        icon: Icon(isEditing ? Icons.save : Icons.play_arrow),
        label: Text(
          isEditing ? 'Save & Continue' : 'View Live Prices',
          style: const TextStyle(fontSize: 16),
        ),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
        ),
      ),
    ];
  }

  List<Widget> _buildGenerateFields() {
    return [
      TextField(
        controller: _pinController,
        keyboardType: TextInputType.number,
        obscureText: true,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Dhan PIN',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.lock_outline),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _totpController,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'TOTP (from authenticator app)',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.timer_outlined),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Requires TOTP to be enabled on your Dhan account. '
        'PIN and TOTP are used once and never stored.',
        style: TextStyle(color: Colors.grey, fontSize: 12),
      ),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: _generating ? null : _generate,
        icon: _generating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.bolt),
        label: Text(
          _generating ? 'Generating…' : 'Generate & Continue',
          style: const TextStyle(fontSize: 16),
        ),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
        ),
      ),
    ];
  }
}

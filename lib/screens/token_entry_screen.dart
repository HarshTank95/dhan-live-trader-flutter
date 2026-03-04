import 'package:flutter/material.dart';
import 'ltp_screen.dart';
import '../services/storage_service.dart';

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

class _TokenEntryScreenState extends State<TokenEntryScreen> {
  late final TextEditingController _clientIdController;
  late final TextEditingController _accessTokenController;

  @override
  void initState() {
    super.initState();
    _clientIdController =
        TextEditingController(text: widget.initialClientId ?? '');
    _accessTokenController =
        TextEditingController(text: widget.initialAccessToken ?? '');
  }

  Future<void> _proceed() async {
    final clientId = _clientIdController.text.trim();
    final accessToken = _accessTokenController.text.trim();

    if (clientId.isEmpty || accessToken.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter both Client ID and Access Token'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await StorageService.saveCredentials(
      clientId: clientId,
      accessToken: accessToken,
    );

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LtpScreen(clientId: clientId, accessToken: accessToken),
      ),
    );
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _accessTokenController.dispose();
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
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            const SizedBox(height: 32),
            TextField(
              controller: _clientIdController,
              decoration: const InputDecoration(
                labelText: 'Client ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 16),
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
          ],
        ),
      ),
    );
  }
}

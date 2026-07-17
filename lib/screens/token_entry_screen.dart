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

class _TokenEntryScreenState extends State<TokenEntryScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _clientIdController;
  late final TextEditingController _accessTokenController;
  final _pinController = TextEditingController();
  final _totpController = TextEditingController();

  // Generate-first: it's the everyday path (tokens expire daily); pasting a
  // ready-made token is the fallback.
  _AuthMode _mode = _AuthMode.generate;
  bool _generating = false;
  String _lastAutoTotp = '';

  @override
  void initState() {
    super.initState();
    _clientIdController =
        TextEditingController(text: widget.initialClientId ?? '');
    _accessTokenController =
        TextEditingController(text: widget.initialAccessToken ?? '');
    WidgetsBinding.instance.addObserver(this);
  }

  /// The whole TOTP dance used to be: switch to the authenticator, copy,
  /// switch back, tap the field, long-press, paste. Now: when the app
  /// RESUMES (i.e. you just came back from the authenticator) the clipboard
  /// is checked — a 6-digit code auto-fills the field. One tap left:
  /// Generate & Continue.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tryAutoFillTotp();
  }

  Future<void> _tryAutoFillTotp({bool manual = false}) async {
    if (!manual && _mode != _AuthMode.generate) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final isCode = RegExp(r'^\d{6}$').hasMatch(text);
    if (!isCode) {
      if (manual) _snack('Clipboard has no 6-digit code', isError: true);
      return;
    }
    if (!manual && text == _lastAutoTotp) return; // don't re-toast same code
    _lastAutoTotp = text;
    if (!mounted) return;
    setState(() => _totpController.text = text);
    _snack('TOTP pasted from clipboard ✓');
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
    WidgetsBinding.instance.removeObserver(this);
    _clientIdController.dispose();
    _accessTokenController.dispose();
    _pinController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  /// Rounded, filled field styling shared by every input on this screen.
  InputDecoration _dec(String label, IconData icon,
      {Widget? suffix, String? hint}) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: cs.primary, width: 1.5),
      ),
    );
  }

  ButtonStyle get _ctaStyle => FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle:
            const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      );

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialClientId != null;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Credentials' : 'Connect to Dhan'),
        backgroundColor: cs.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            // Hero badge
            Center(
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.blue.shade400,
                      Colors.indigo.shade600,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(Icons.candlestick_chart,
                    size: 38, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEditing ? 'Refresh your session' : 'Welcome — let\'s connect',
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 13, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  'Credentials never leave this device',
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 22),
            // Generate first — it's the daily-driver path.
            SegmentedButton<_AuthMode>(
              style: SegmentedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              segments: const [
                ButtonSegment(
                  value: _AuthMode.generate,
                  label: Text('Generate token'),
                  icon: Icon(Icons.bolt_outlined),
                ),
                ButtonSegment(
                  value: _AuthMode.paste,
                  label: Text('Paste token'),
                  icon: Icon(Icons.key_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _generating
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 20),
            // Form card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _clientIdController,
                    decoration: _dec('Client ID', Icons.person_outline),
                  ),
                  const SizedBox(height: 14),
                  if (_mode == _AuthMode.paste)
                    ..._buildPasteFields()
                  else
                    ..._buildGenerateFields(),
                ],
              ),
            ),
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
        maxLines: 4,
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        decoration: _dec('Access Token', Icons.key_outlined,
            hint: 'Paste the token from web.dhan.co → My profile → DhanHQ'),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _proceed,
        style: _ctaStyle,
        icon: Icon(isEditing ? Icons.save_outlined : Icons.play_arrow),
        label: Text(isEditing ? 'Save & Continue' : 'Start'),
      ),
    ];
  }

  List<Widget> _buildGenerateFields() {
    final cs = Theme.of(context).colorScheme;
    return [
      TextField(
        controller: _pinController,
        keyboardType: TextInputType.number,
        obscureText: true,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: _dec('Dhan PIN', Icons.lock_outline),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _totpController,
        keyboardType: TextInputType.number,
        style: const TextStyle(
            fontSize: 18, letterSpacing: 6, fontWeight: FontWeight.w600),
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: _dec('TOTP code', Icons.timer_outlined,
            hint: '••••••',
            // One-tap fallback; the field also auto-fills whenever you come
            // back from the authenticator with a code on the clipboard.
            suffix: IconButton(
              tooltip: 'Paste code',
              icon: const Icon(Icons.content_paste_go),
              onPressed: () => _tryAutoFillTotp(manual: true),
            )),
      ),
      const SizedBox(height: 12),
      // Auto-paste explainer chip
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 16, color: Colors.blue.shade300),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Copy the code in your authenticator and switch back — '
                'it fills in by itself.',
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant, height: 1.3),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _generating ? null : _generate,
        style: _ctaStyle,
        icon: _generating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.bolt),
        label: Text(_generating ? 'Generating…' : 'Generate & Continue'),
      ),
      const SizedBox(height: 10),
      Center(
        child: Text(
          'PIN and TOTP are used once and never stored',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5),
        ),
      ),
    ];
  }
}

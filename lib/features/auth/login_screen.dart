import 'package:flutter/material.dart';
import '../../shared/services/session_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.session,
    required this.emailDeliveryEnabled,
    this.deletionStatusScreen,
  });
  final SessionService session;
  final bool emailDeliveryEnabled;
  final Widget? deletionStatusScreen;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(), _password = TextEditingController();
  bool _busy = false;
  String? _message;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({bool recovery = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (recovery) {
        await widget.session.requestRecovery(_email.text);
        if (mounted) {
          setState(
            () => _message =
                'If this address can receive beta recovery email, a link will arrive shortly.',
          );
        }
      } else if (widget.session.recoveryRequired) {
        if (_password.text.length < 12) throw const FormatException();
        await widget.session.updatePassword(_password.text);
      } else {
        await widget.session.signIn(_email.text, _password.text);
      }
      _password.clear();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = widget.session.recoveryRequired
              ? 'Use a password with at least 12 characters. If the link expired, request another.'
              : 'Sign-in could not be completed. Check your account details and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Safe at Home')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                widget.session.recoveryRequired
                    ? 'Choose a new password'
                    : 'Sign in to the private beta',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Use fictional resident information during the team beta.',
              ),
              const SizedBox(height: 24),
              if (!widget.session.recoveryRequired)
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              TextField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: [
                  widget.session.recoveryRequired
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: widget.session.recoveryRequired
                      ? 'New password (12+ characters)'
                      : 'Password',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : () => _submit(),
                child: Text(
                  _busy
                      ? 'Please wait…'
                      : widget.session.recoveryRequired
                      ? 'Save password'
                      : 'Sign in',
                ),
              ),
              if (widget.emailDeliveryEnabled &&
                  !widget.session.recoveryRequired)
                TextButton(
                  onPressed: _busy ? null : () => _submit(recovery: true),
                  child: const Text('Forgot password'),
                ),
              if (!widget.emailDeliveryEnabled)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Sign in with your provisioned team account. Email registration and recovery are not enabled for this beta.',
                  ),
                ),
              if (widget.deletionStatusScreen != null)
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => widget.deletionStatusScreen!,
                    ),
                  ),
                  child: const Text('Check pending account deletion'),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_message!, semanticsLabel: _message),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

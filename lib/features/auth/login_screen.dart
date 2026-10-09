import 'package:flutter/material.dart';
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/session_service.dart';
import '../settings/language_section.dart';

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
  bool _busy = false, _passwordVisible = false;
  String? _message;
  int _feedbackRevision = 0;
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
      _feedbackRevision++;
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
      if (!mounted) return;
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

  void _clearFeedback(String _) {
    if (_message != null) setState(() => _message = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recovering = widget.session.recoveryRequired;
    return Scaffold(
      appBar: AppBar(
        actions: const [LanguageButton()],
        title: Row(
          children: [
            const SahBrandMark(size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Safe at Home',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SahContent(
          maxWidth: 480,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SahStatusBadge(
                    label: context.tr('Private team beta'),
                    icon: Icons.lock_outline_rounded,
                  ),
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final showIllustration =
                        !recovering &&
                        constraints.maxWidth >= 330 &&
                        MediaQuery.textScalerOf(context).scale(16) <= 22.4;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              recovering
                                  ? context.tr('Choose a new password')
                                  : context.tr('Welcome back'),
                              style: theme.textTheme.headlineLarge,
                            ),
                          ),
                        ),
                        if (showIllustration) ...[
                          const SizedBox(width: 12),
                          const SizedBox(
                            width: 80,
                            child: SahHomeIllustration(height: 72),
                          ),
                        ],
                      ],
                    );
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  recovering
                      ? context.tr('Choose a new password.')
                      : context.tr('Sign in to continue.'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(SahRadius.large),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!recovering)
                        TextField(
                          key: const ValueKey('login-email'),
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          textCapitalization: TextCapitalization.none,
                          autofillHints: const [AutofillHints.username],
                          enabled: !_busy,
                          onChanged: _clearFeedback,
                          decoration: InputDecoration(
                            label: Text(context.tr('Email')),
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                          ),
                        ),
                      if (!recovering) const SizedBox(height: 20),
                      TextField(
                        key: const ValueKey('login-password'),
                        controller: _password,
                        obscureText: !_passwordVisible,
                        textInputAction: TextInputAction.done,
                        enableSuggestions: false,
                        autocorrect: false,
                        autofillHints: [
                          recovering
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        enabled: !_busy,
                        onChanged: _clearFeedback,
                        decoration: InputDecoration(
                          label: Text(
                            recovering
                                ? context.tr('New password (12+ characters)')
                                : context.tr('Password'),
                          ),
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: _passwordVisible
                                ? context.tr('Hide password')
                                : context.tr('Show password'),
                            onPressed: _busy
                                ? null
                                : () => setState(
                                    () => _passwordVisible = !_passwordVisible,
                                  ),
                            icon: Icon(
                              _passwordVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('auth-sign-in'),
                        onPressed: _busy ? null : () => _submit(),
                        child: Text(
                          _busy
                              ? context.tr('Please wait…')
                              : recovering
                              ? context.tr('Save password')
                              : context.tr('Sign in'),
                        ),
                      ),
                      if (widget.emailDeliveryEnabled && !recovering)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _submit(recovery: true),
                          child: Text(context.tr('Forgot password')),
                        ),
                      if (_message != null)
                        SahActionFeedback(
                          key: const ValueKey('auth-action-feedback'),
                          message: context.tr(_message!),
                          revealRevision: _feedbackRevision,
                          tone: SahNoticeTone.warning,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  context.tr('Team beta: use fictional information only.'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                if (widget.deletionStatusScreen != null) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => widget.deletionStatusScreen!,
                      ),
                    ),
                    child: Text(context.tr('Check pending account deletion')),
                  ),
                ],
                if (widget.session.callbackNotice != null)
                  SahNotice(
                    message: context.tr(widget.session.callbackNotice!),
                    tone: SahNoticeTone.warning,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

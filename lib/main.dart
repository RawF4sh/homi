import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'app/appearance.dart';
import 'app/live_app.dart';
import 'app/safe_at_home_app.dart';
import 'app/theme.dart';
import 'shared/presentation/sah_components.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    AppAppearance.instance.load(),
    AppLanguageController.instance.load(),
  ]);
  const live = bool.fromEnvironment('SAH_LIVE_BACKEND');
  runApp(live ? const LiveAppBootstrap() : const _DemoEntry());
}

class _DemoEntry extends StatelessWidget {
  const _DemoEntry();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      AppAppearance.instance,
      AppLanguageController.instance,
    ]),
    builder: (context, _) => MaterialApp(
      title: 'Safe at Home',
      theme: SafeAtHomeTheme.light(),
      darkTheme: SafeAtHomeTheme.dark(),
      themeMode: AppAppearance.instance.value,
      locale: AppLanguageController.instance.value.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeListResolutionCallback: AppLocalizations.resolveLocales,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Safe at Home')),
        body: SafeArea(
          child: Builder(
            builder: (context) => SahContent(
              maxWidth: 600,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SahHomeIllustration(height: 160),
                  const SizedBox(height: 16),
                  const SahPageHeader(
                    eyebrow: 'A LITTLE SUPPORT, AT HOME',
                    title: 'A safer home starts here.',
                    description:
                        'Review your space, explore possible support, and prepare your next steps.',
                  ),
                  const SahNotice(
                    title: 'Fictional demonstration',
                    message:
                        'Live account access is not enabled in this build. The examples below use bundled fictional information and do not send data to a server.',
                    icon: Icons.science_outlined,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SafeAtHomeApp(),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Open fictional examples'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

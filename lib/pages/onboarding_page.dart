import 'package:flutter/material.dart';
import '../app_settings.dart';

// First-launch guide: what the app does, how to wear the RESpeck and how to
// get connected. Wearing the sensor the same way as in the training data
// matters more for live accuracy than anything else, so it is shown before
// the app is first used, and can be reopened from Settings.
class OnboardingPage extends StatefulWidget {
  // Opened again from Settings (pop when done) rather than at first launch
  final bool fromSettings;
  const OnboardingPage({super.key, this.fromSettings = false});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _Step {
  final IconData icon;
  final String title;
  final List<String> points;
  const _Step(this.icon, this.title, this.points);
}

const List<_Step> _steps = [
  _Step(Icons.monitor_heart, 'Welcome', [
    'This app uses the RESpeck sensor to recognise what you are doing - '
        'sitting, lying, walking, running, climbing stairs and more.',
    'While you are still, it also detects normal breathing, coughing, '
        'hyperventilating and talking or eating.',
    'Everything runs on your phone, and your history stays on it.',
  ]),
  _Step(Icons.accessibility_new, 'Wear the RESpeck', [
    'Attach the RESpeck in exactly the position and orientation used when '
        'the training data was recorded, as shown in the lab instructions.',
    'Fix it firmly against the skin so it cannot slide or rotate.',
    'A sensor that is moved or turned is the most common reason for wrong '
        'results, especially for lying positions.',
  ]),
  _Step(Icons.bluetooth_connected, 'Connect', [
    'Pair your RESpeck once in Settings › RESpeck pairing by scanning the QR '
        'code on its back.',
    'Then press Connect on the Live tab. The first activity appears after '
        'about 4 s, and breathing after about 10 s of keeping still.',
    'Results are saved automatically, so you can review your day on the '
        'History tab.',
  ]),
];

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    appSettings.setOnboardingDone(true);
    if (widget.fromSettings) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _page == _steps.length - 1;
    return Scaffold(
      appBar: widget.fromSettings
          ? AppBar(title: const Text('How to use the app'))
          : null,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final s in _steps)
                    SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 48, 28, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(s.icon,
                                size: 52,
                                color: theme.colorScheme.onPrimaryContainer),
                          ),
                          const SizedBox(height: 28),
                          Text(s.title,
                              style: theme.textTheme.headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 20),
                          for (final p in s.points)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Icon(Icons.check_circle,
                                        size: 18,
                                        color: theme.colorScheme.primary),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(p,
                                          style: theme.textTheme.bodyLarge)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  for (int i = 0; i < _steps.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const Spacer(),
                  if (!last)
                    TextButton(onPressed: _finish, child: const Text('Skip')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: last
                        ? _finish
                        : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut),
                    child: Text(last ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

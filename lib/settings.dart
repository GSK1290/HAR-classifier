import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'globals.dart';
import 'har.dart';
import 'history.dart';
import 'labels.dart';
import 'pages/data_collection_page.dart';
import 'pages/onboarding_page.dart';
import 'scanning.dart';
import 'utils.dart';
import 'widgets/common.dart';

// The Settings tab: sensor pairing, classification options, reminders,
// appearance, data management and help.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const _Header('Sensor'),
            ListTile(
              leading: const Icon(Icons.sensors),
              title: const Text('RESpeck pairing'),
              subtitle: Text((respeckUUID == null || respeckUUID!.isEmpty)
                  ? 'Not paired'
                  : 'Subject $subjectID · RESpeck $respeckUUID'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const PairingPage()));
                appSettings.pairingChanged();
              },
            ),
            const _Header('Classification'),
            SwitchListTile(
              secondary: const Icon(Icons.timer_outlined),
              title: const Text('Faster updates'),
              subtitle: const Text(
                  'New result about every 1 s instead of every 2 s. '
                  'Uses a little more battery.'),
              value: appSettings.fastUpdates,
              onChanged: appSettings.setFastUpdates,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.waves),
              title: const Text('Smooth results'),
              subtitle: const Text(
                  'Show the most common of the last 3 results. Fewer '
                  'flickers, but reacts about one update later.'),
              value: appSettings.smoothing,
              onChanged: appSettings.setSmoothing,
            ),
            ListTile(
              leading: const Icon(Icons.model_training),
              title: const Text('About the models'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showModels(context),
            ),
            const _Header('Reminders'),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Remind me to move after'),
              trailing: DropdownButton<int>(
                value: appSettings.inactivityMinutes,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off')),
                  DropdownMenuItem(value: 30, child: Text('30 min')),
                  DropdownMenuItem(value: 60, child: Text('60 min')),
                  DropdownMenuItem(value: 90, child: Text('90 min')),
                ],
                onChanged: (v) {
                  if (v != null) appSettings.setInactivityMinutes(v);
                },
              ),
            ),
            const _Header('Appearance'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode)),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode)),
                ],
                selected: {appSettings.themeMode},
                onSelectionChanged: (s) => appSettings.setThemeMode(s.first),
              ),
            ),
            const _Header('Data'),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('Export history as CSV'),
              onTap: () async {
                final f = await history.exportAll();
                if (!context.mounted) return;
                await showExportDialog(
                    context, 'History exported', [if (f != null) f]);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear history'),
              onTap: () async {
                if (await confirm(context, 'Clear all history?',
                    'This deletes every stored result on this phone.')) {
                  await history.clear();
                  showToast('History cleared');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.fiber_manual_record_outlined),
              title: const Text('Data collection'),
              subtitle: const Text('Record labelled raw sensor data'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DataCollectionPage())),
            ),
            const _Header('Help'),
            ListTile(
              leading: const Icon(Icons.accessibility_new),
              title: const Text('How to wear the RESpeck'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          const OnboardingPage(fromSettings: true))),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('App version'),
              trailing: Text('$appVersionName ($appVersionCode)'),
            ),
          ],
        ),
      ),
    );
  }

  void _showModels(BuildContext context) {
    Widget model(String title, HarClassifier? c, List<ClassInfo> classes) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (c == null)
            const Text('Not loaded')
          else ...[
            InfoRow('Window', '${c.windowSeconds.toStringAsFixed(0)} s '
                '(${c.window.length} samples)'),
            InfoRow('Update every', '${c.stepSeconds.toStringAsFixed(1)} s'),
            InfoRow('Classes', '${c.classes.length}'),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in classes)
                Chip(
                  avatar: Icon(k.icon, size: 16, color: k.color),
                  label: Text(k.name),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      );
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Models'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Both models run on the phone with TensorFlow Lite, '
                  'on RESpeck accelerometer data sampled at 12.5 Hz.'),
              const SizedBox(height: 12),
              model('Physical activity', harClassifier, activityClasses),
              const SizedBox(height: 16),
              model('Breathing & social signals', socialClassifier,
                  socialClasses),
              const SizedBox(height: 8),
              const Text('Social signals are only shown while the activity '
                  'model says you are still, because the model was trained '
                  'on stationary data only.'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8)),
    );
  }
}

// Pair the app with a subject ID and RESpeck (by QR code or by hand).
// This is the original settings screen of the template.
class PairingPage extends StatefulWidget {
  const PairingPage({super.key});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  // Both fields start out holding the current pairing. Saving writes back
  // whatever is in the fields, so pre-filling them is what stops an edit to
  // one field from wiping the other.
  final TextEditingController subjectController = TextEditingController();
  final TextEditingController respeckController = TextEditingController();

  @override
  void initState() {
    super.initState();
    subjectController.text = subjectID ?? "";
    respeckController.text = respeckUUID ?? "";
  }

  @override
  void dispose() {
    subjectController.dispose();
    respeckController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RESpeck pairing')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Current pairing',
            icon: Icons.link,
            child: Column(
              children: [
                InfoRow('Subject', subjectID ?? '-'),
                InfoRow('RESpeck', respeckUUID ?? '-'),
                InfoRow('Storage folder',
                    storageFolder?.path.split('/').last ?? 'Not available'),
              ],
            ),
          ),
          SectionCard(
            title: 'New pairing',
            icon: Icons.qr_code,
            child: Column(
              children: [
                TextField(
                  controller: subjectController,
                  decoration: const InputDecoration(
                      labelText: 'Subject ID', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: respeckController,
                  decoration: const InputDecoration(
                      labelText: 'RESpeck ID', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                          onPressed: () => _scanQRCode(context),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan QR code')),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _save,
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    // Store the new subject and respeck IDs in shared preferences to survive
    // app restarts
    final String newSubject = subjectController.text.trim();
    final String newRespeck = respeckController.text.trim();

    await asyncPrefs.setString('rid', newRespeck);
    await asyncPrefs.setString('sid', newSubject);

    if (!mounted) return;
    setState(() {
      respeckUUID = newRespeck;
      subjectID = newSubject;
    });
    showToast("Settings saved");
  }

  // Launch the QR code scanner, which appears in a new page
  Future<void> _scanQRCode(BuildContext context) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ScanningPage()),
    );

    // When a BuildContext is used from a StatefulWidget, the mounted property
    // must be checked after an asynchronous gap.
    if (!context.mounted) return;

    // The scanner returns null if the user backed out without scanning
    // anything, so the result cannot be assigned to the field unchecked
    if (result is! String || result.isEmpty) {
      showToast("No QR code scanned");
      return;
    }

    respeckController.text = result;
  }
}

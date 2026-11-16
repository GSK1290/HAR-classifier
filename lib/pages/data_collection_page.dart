import 'package:flutter/material.dart';
import '../live.dart';
import '../recorder.dart';
import '../widgets/common.dart';

// Record labelled raw RESpeck data to CSV - the data collection screen from
// the labs, moved out of the main screen. The recording continues if the
// user leaves this page.
class DataCollectionPage extends StatelessWidget {
  const DataCollectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data collection')),
      body: ListenableBuilder(
        listenable: Listenable.merge([recorder, live]),
        builder: (context, _) {
          final theme = Theme.of(context);
          final connected = live.lastPacketAt != null;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: 'Label',
                icon: Icons.label_outline,
                child: Column(
                  children: [
                    _dropdown('Activity', recorder.activity,
                        Recorder.activities, recorder.setActivity,
                        enabled: !recorder.recording),
                    const SizedBox(height: 12),
                    _dropdown('Social signal', recorder.signal,
                        Recorder.signals, recorder.setSignal,
                        enabled: !recorder.recording),
                  ],
                ),
              ),
              SectionCard(
                title: 'Recording',
                icon: Icons.fiber_manual_record,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.circle,
                            size: 12,
                            color:
                                recorder.recording ? Colors.red : Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(child: Text(recorder.info)),
                      ],
                    ),
                    if (recorder.filename.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(recorder.filename,
                          style: theme.textTheme.bodySmall),
                    ],
                    if (!connected) ...[
                      const SizedBox(height: 6),
                      Text('Connect the RESpeck on the Live tab first.',
                          style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: recorder.recording
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red),
                              onPressed: () => recorder.stop(),
                              icon: const Icon(Icons.stop),
                              label: const Text('Stop recording'))
                          : FilledButton.icon(
                              onPressed: connected ? recorder.start : null,
                              icon: const Icon(Icons.fiber_manual_record),
                              label: const Text('Start recording')),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> options,
      void Function(String) onChanged,
      {required bool enabled}) {
    return InputDecorator(
      decoration: InputDecoration(
          labelText: label, border: const OutlineInputBorder(), isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [
            for (final o in options)
              DropdownMenuItem<String>(value: o, child: Text(o)),
          ],
          onChanged: enabled
              ? (v) {
                  if (v != null) onChanged(v);
                }
              : null,
        ),
      ),
    );
  }
}

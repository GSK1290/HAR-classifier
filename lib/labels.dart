import 'package:flutter/material.dart';

// Display information for every class the two models can output: a readable
// name, an icon and a colour. The same colour is used for a class everywhere
// in the app (live cards, timelines, charts), so the user can recognise an
// activity at a glance.
//
// The ids must match the class names in the models' metadata files exactly
// (see assets/models/*_meta.json).

enum ClassKind { activity, social }

class ClassInfo {
  // Class name as output by the model, e.g. "lyingLeft"
  final String id;
  // Name shown to the user, e.g. "Lying on left side"
  final String name;
  final IconData icon;
  final Color color;
  final ClassKind kind;
  // Activities only: true for the five static postures. The social signal
  // model was trained on stationary data only, so its output is only shown
  // while the activity is one of these.
  final bool stationary;

  const ClassInfo(this.id, this.name, this.icon, this.color, this.kind,
      {this.stationary = false});
}

const List<ClassInfo> activityClasses = [
  ClassInfo('sittingStanding', 'Sitting / standing', Icons.chair_alt,
      Color(0xFF4E79A7), ClassKind.activity,
      stationary: true),
  ClassInfo('lyingBack', 'Lying on back', Icons.airline_seat_flat,
      Color(0xFF59A14F), ClassKind.activity,
      stationary: true),
  ClassInfo('lyingLeft', 'Lying on left side', Icons.hotel, Color(0xFF8CD17D),
      ClassKind.activity,
      stationary: true),
  ClassInfo('lyingRight', 'Lying on right side', Icons.hotel,
      Color(0xFF499894), ClassKind.activity,
      stationary: true),
  ClassInfo('lyingStomach', 'Lying on stomach', Icons.airline_seat_flat_angled,
      Color(0xFF86BCB6), ClassKind.activity,
      stationary: true),
  ClassInfo('normalWalking', 'Walking', Icons.directions_walk,
      Color(0xFFF28E2B), ClassKind.activity),
  ClassInfo('shuffleWalking', 'Shuffle walking', Icons.elderly,
      Color(0xFFFFBE7D), ClassKind.activity),
  ClassInfo('ascending', 'Climbing stairs', Icons.stairs, Color(0xFFE15759),
      ClassKind.activity),
  ClassInfo('descending', 'Descending stairs', Icons.stairs_outlined,
      Color(0xFFFF9D9A), ClassKind.activity),
  ClassInfo('running', 'Running', Icons.directions_run, Color(0xFFB07AA1),
      ClassKind.activity),
  ClassInfo('miscMovement', 'Other movement', Icons.accessibility_new,
      Color(0xFF9D7660), ClassKind.activity),
];

const List<ClassInfo> socialClasses = [
  ClassInfo('breathingNormally', 'Breathing normally', Icons.air,
      Color(0xFF76B7B2), ClassKind.social),
  ClassInfo('coughing', 'Coughing', Icons.sick, Color(0xFFD37295),
      ClassKind.social),
  ClassInfo('hyperventilation', 'Hyperventilating', Icons.monitor_heart,
      Color(0xFFEDC948), ClassKind.social),
  ClassInfo('other', 'Talking / eating / laughing', Icons.record_voice_over,
      Color(0xFFBAB0AC), ClassKind.social),
];

final Map<String, ClassInfo> _byId = {
  for (final c in [...activityClasses, ...socialClasses]) c.id: c,
};

// Look up a class by its model id. An unknown id (e.g. from a different model)
// still gets a usable grey entry rather than crashing the UI.
ClassInfo classInfo(String id) =>
    _byId[id] ??
    ClassInfo(id, id, Icons.help_outline, Colors.grey, ClassKind.activity);

// Format a duration compactly: "45 s", "12 min", "2 h 05 min"
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) {
    final s = d.inSeconds % 60;
    return s == 0 || d.inMinutes >= 10
        ? '${d.inMinutes} min'
        : '${d.inMinutes} min ${s.toString().padLeft(2, '0')} s';
  }
  final m = d.inMinutes % 60;
  return '${d.inHours} h ${m.toString().padLeft(2, '0')} min';
}

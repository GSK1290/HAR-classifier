import 'package:flutter/material.dart';
import 'globals.dart';
import 'har.dart';

// User preferences, stored in shared preferences so they survive restarts.
// Widgets listen to `appSettings` and rebuild when a value changes.
class AppSettings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  // Show the majority vote of the last 3 predictions instead of the latest
  // one: steadier labels, at the cost of reacting about one step later
  bool smoothing = false;
  // Run both models every ~1 s instead of every 2 s
  bool fastUpdates = false;
  // Remind the user after this many minutes without moving. 0 = off.
  int inactivityMinutes = 60;
  // True once the first-launch guide has been completed
  bool onboardingDone = false;

  Future<void> load() async {
    try {
      final theme = await asyncPrefs.getString('themeMode');
      themeMode = ThemeMode.values.firstWhere((m) => m.name == theme,
          orElse: () => ThemeMode.system);
      smoothing = await asyncPrefs.getBool('smoothing') ?? false;
      fastUpdates = await asyncPrefs.getBool('fastUpdates') ?? false;
      inactivityMinutes = await asyncPrefs.getInt('inactivityMinutes') ?? 60;
      onboardingDone = await asyncPrefs.getBool('onboardingDone') ?? false;
    } catch (e) {
      // Defaults are fine if the preferences cannot be read
      print("Could not read settings: $e");
    }
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    asyncPrefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setSmoothing(bool on) {
    smoothing = on;
    asyncPrefs.setBool('smoothing', on);
    notifyListeners();
  }

  void setFastUpdates(bool on) {
    fastUpdates = on;
    asyncPrefs.setBool('fastUpdates', on);
    applyUpdateRate();
    notifyListeners();
  }

  // Apply the update rate setting to the loaded classifiers
  void applyUpdateRate() {
    harClassifier?.setFastUpdates(fastUpdates);
    socialClassifier?.setFastUpdates(fastUpdates);
  }

  void setInactivityMinutes(int minutes) {
    inactivityMinutes = minutes;
    asyncPrefs.setInt('inactivityMinutes', minutes);
    notifyListeners();
  }

  // The pairing is stored in globals.dart rather than here; this tells the
  // Settings tab to redraw after it changes
  void pairingChanged() => notifyListeners();

  void setOnboardingDone(bool done) {
    onboardingDone = done;
    asyncPrefs.setBool('onboardingDone', done);
    notifyListeners();
  }
}

final AppSettings appSettings = AppSettings();

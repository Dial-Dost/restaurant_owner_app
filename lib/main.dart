import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'services/restaurant_time.dart';
import 'ui/theme/appearance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply any device-persisted server override before the first network call.
  await AppConfig.loadBackendOverride();
  // Restore the restaurant's timezone before the first frame so timestamps are
  // right on a cold start instead of flipping once /restaurant/timezones lands.
  await RestaurantTime.restore();
  // Apply this device's saved accent BEFORE the first frame, so the app never
  // flashes copper and then recolours (per-device setting — see appearance.dart).
  await AppearanceController.instance.load();
  runApp(const OwnerApp());
}

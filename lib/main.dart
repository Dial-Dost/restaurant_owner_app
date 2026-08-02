import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'services/restaurant_time.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply any device-persisted server override before the first network call.
  await AppConfig.loadBackendOverride();
  // Restore the restaurant's timezone before the first frame so timestamps are
  // right on a cold start instead of flipping once /restaurant/timezones lands.
  await RestaurantTime.restore();
  runApp(const OwnerApp());
}

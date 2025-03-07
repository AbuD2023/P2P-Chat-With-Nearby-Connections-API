import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'services/message_service.dart';
import 'screens/device_discovery_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectionService()),
        ChangeNotifierProvider(create: (_) => MessageService()),
      ],
      child: MaterialApp(
        title: 'P2P Chat',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const DeviceDiscoveryScreen(),
      ),
    );
  }
}

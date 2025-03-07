import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import 'chat_screen.dart';

class DeviceDiscoveryScreen extends StatefulWidget {
  const DeviceDiscoveryScreen({super.key});

  @override
  State<DeviceDiscoveryScreen> createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    _initializeConnection();
  }

  Future<void> _initializeConnection() async {
    final connectionService =
        Provider.of<ConnectionService>(context, listen: false);

    // قطع الاتصال مع جميع الأجهزة أولاً
    await connectionService.disconnectFromAllDevices();

    // ثم بدء الإعلان والاكتشاف
    await connectionService.startAdvertising();
    await connectionService.startDiscovery();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _initializeConnection,
          ),
        ],
      ),
      body: Consumer<ConnectionService>(
        builder: (context, connectionService, child) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: connectionService.discoveredDevices.length,
                  itemBuilder: (context, index) {
                    final device = connectionService.discoveredDevices[index];
                    final bool isConnected =
                        connectionService.connectedDevices.contains(device.id);

                    return ListTile(
                      leading: Icon(
                        isConnected
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth,
                        color: isConnected ? Colors.green : Colors.grey,
                      ),
                      title: Text(device.name),
                      subtitle: Text(isConnected ? 'Connected' : 'Available'),
                      trailing: isConnected
                          ? ElevatedButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ChatScreen(
                                        deviceId: device.id,
                                        deviceName: device.name),
                                  ),
                                );
                              },
                              child: const Text('Chat'),
                            )
                          : ElevatedButton(
                              onPressed: () async {
                                await connectionService
                                    .connectToDevice(device.id);
                              },
                              child: const Text('Connect'),
                            ),
                    );
                  },
                ),
              ),
              if (connectionService.discoveredDevices.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'No devices found nearby.\nMake sure Bluetooth and Location are enabled.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    final connectionService =
        Provider.of<ConnectionService>(context, listen: false);
    connectionService.stopDiscovery();
    connectionService.stopAdvertising();
    super.dispose();
  }
}

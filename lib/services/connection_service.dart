import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

class ConnectionService extends ChangeNotifier {
  final Strategy _strategy = Strategy.P2P_POINT_TO_POINT;
  final String _serviceId = 'com.example.blutoth_app_wifi';
  final _nearby = Nearby();
  static const int _maxRetries = 3;
  static const int _delayMs = 1000;

  List<Device> discoveredDevices = [];
  List<String> connectedDevices = [];
  List<Message> messages = [];
  bool isDiscovering = false;
  bool isAdvertising = false;
  bool isConnecting = false;
  Map<String, double> fileTransferProgress = {};
  String? currentConnectingDevice;

  // إضافة متغير لمسار حفظ المحادثات
  String? _chatStoragePath;

  // إضافة متغير لمسار حفظ الأجهزة
  String? _devicesStoragePath;
  Map<String, List<Message>> deviceMessages = {};
  List<Device> savedDevices = [];

  // تهيئة مسار حفظ المحادثات
  Future<void> initChatStorage() async {
    final baseDir = Directory(
        '/storage/emulated/0/Android/media/com.example.blutoth_app_wifi/chats');
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    _chatStoragePath = baseDir.path;
    await loadMessages();
  }

  // حفظ المحادثات
  Future<void> saveMessages() async {
    try {
      if (_chatStoragePath == null) await initChatStorage();

      final messagesFile =
          File(path.join(_chatStoragePath!, 'chat_history.json'));
      final List<Map<String, dynamic>> messagesList =
          messages.map((m) => m.toJson()).toList();
      await messagesFile.writeAsString(jsonEncode(messagesList));
      log('Messages saved successfully');
    } catch (e) {
      log('Error saving messages: $e');
    }
  }

  // تحميل المحادثات
  Future<void> loadMessages() async {
    try {
      if (_chatStoragePath == null) await initChatStorage();

      final messagesFile =
          File(path.join(_chatStoragePath!, 'chat_history.json'));
      if (await messagesFile.exists()) {
        final String content = await messagesFile.readAsString();
        final List<dynamic> messagesList = jsonDecode(content);
        messages = messagesList.map((m) => Message.fromJson(m)).toList();
        notifyListeners();
        log('Messages loaded successfully');
      }
    } catch (e) {
      log('Error loading messages: $e');
    }
  }

  // تهيئة مسار حفظ الأجهزة
  Future<void> initDeviceStorage() async {
    final baseDir = Directory(
        '/storage/emulated/0/Android/media/com.example.blutoth_app_wifi/devices');
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    _devicesStoragePath = baseDir.path;
    await loadDevices();
  }

  // حفظ الأجهزة
  Future<void> saveDevices() async {
    try {
      if (_devicesStoragePath == null) await initDeviceStorage();

      final devicesFile = File(path.join(_devicesStoragePath!, 'devices.json'));
      final List<Map<String, dynamic>> devicesList = savedDevices
          .map((d) => {
                'id': d.id,
                'name': d.name,
              })
          .toList();
      await devicesFile.writeAsString(jsonEncode(devicesList));
      log('Devices saved successfully');
    } catch (e) {
      log('Error saving devices: $e');
    }
  }

  // تحميل الأجهزة
  Future<void> loadDevices() async {
    try {
      if (_devicesStoragePath == null) await initDeviceStorage();

      final devicesFile = File(path.join(_devicesStoragePath!, 'devices.json'));
      if (await devicesFile.exists()) {
        final String content = await devicesFile.readAsString();
        final List<dynamic> devicesList = jsonDecode(content);
        savedDevices = devicesList
            .map((d) => Device(
                  id: d['id'],
                  name: d['name'],
                ))
            .toList();

        // تحميل محادثات كل جهاز
        for (var device in savedDevices) {
          await loadDeviceMessages(device.id);
        }

        notifyListeners();
        log('Devices and their messages loaded successfully');
      }
    } catch (e) {
      log('Error loading devices: $e');
    }
  }

  // حفظ محادثات جهاز معين
  Future<void> saveDeviceMessages(String deviceId) async {
    try {
      if (_chatStoragePath == null) await initChatStorage();

      final deviceChatsFile =
          File(path.join(_chatStoragePath!, 'chat_$deviceId.json'));
      final messages = deviceMessages[deviceId] ?? [];
      final List<Map<String, dynamic>> messagesList =
          messages.map((m) => m.toJson()).toList();
      await deviceChatsFile.writeAsString(jsonEncode(messagesList));
      log('Messages saved for device: $deviceId');
    } catch (e) {
      log('Error saving messages for device $deviceId: $e');
    }
  }

  // تحميل محادثات جهاز معين
  Future<void> loadDeviceMessages(String deviceId) async {
    try {
      if (_chatStoragePath == null) await initChatStorage();

      final deviceChatsFile =
          File(path.join(_chatStoragePath!, 'chat_$deviceId.json'));
      if (await deviceChatsFile.exists()) {
        final String content = await deviceChatsFile.readAsString();
        final List<dynamic> messagesList = jsonDecode(content);
        deviceMessages[deviceId] =
            messagesList.map((m) => Message.fromJson(m)).toList();
        log('Messages loaded for device: $deviceId');
      } else {
        deviceMessages[deviceId] = [];
      }
    } catch (e) {
      log('Error loading messages for device $deviceId: $e');
    }
  }

  Future<void> _delay() async {
    await Future.delayed(Duration(milliseconds: _delayMs));
  }

  Future<bool> _retryOperation(Future<void> Function() operation) async {
    int attempts = 0;
    while (attempts < _maxRetries) {
      try {
        await operation();
        return true;
      } catch (e) {
        attempts++;
        log('Operation failed, attempt $attempts of $_maxRetries: $e');
        if (attempts < _maxRetries) {
          await _delay();
        }
      }
    }
    return false;
  }

  Future<bool> checkPermissions() async {
    try {
      // Check location service
      if (!await Permission.location.serviceStatus.isEnabled) {
        log('Location services are disabled');
        return false;
      }

      // Request essential permissions first
      Map<Permission, PermissionStatus> essentialStatuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.storage,
        Permission.microphone,
        // Permission.manageExternalStorage,
      ].request();

      // Check essential permissions
      bool essentialGranted = true;
      essentialStatuses.forEach((permission, status) {
        log('${permission.toString()} status: ${status.name}');
        if (!status.isGranted) {
          log('${permission.toString()} was not granted');
          essentialGranted = false;
        }
      });

      if (!essentialGranted) {
        // Try requesting denied essential permissions individually
        for (var entry in essentialStatuses.entries) {
          if (!entry.value.isGranted) {
            log('Requesting ${entry.key.toString()} individually');
            final status = await entry.key.request();
            if (!status.isGranted) {
              log('${entry.key.toString()} still not granted');
              return false;
            }
          }
        }
      }

      // إنشاء المجلدات الضرورية
      await _initializeDirectories();

      log('Essential permissions granted: $essentialGranted');
      return essentialGranted;
    } catch (e) {
      log('Error requesting permissions: $e');
      return false;
    }
  }

  Future<void> _initializeDirectories() async {
    try {
      final baseDir = Directory(
          '/storage/emulated/0/Android/media/com.example.blutoth_app_wifi');
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }

      final directories = ['images', 'videos', 'audio', 'files', 'temp'];
      for (var dir in directories) {
        final directory = Directory(path.join(baseDir.path, dir));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
      }

      log('All required directories created successfully');
    } catch (e) {
      log('Error creating directories: $e');
    }
  }

  Future<void> startAdvertising() async {
    log('Starting advertising...');

    // إيقاف جميع الخدمات أولاً
    await _stopAllServices();

    // Double check permissions
    if (!await checkPermissions()) {
      log('Required permissions not granted');
      return;
    }

    // Try to start advertising with increased delay
    final success = await _retryOperation(() async {
      final deviceName = await _getDeviceName();
      log('Starting advertising with device name: $deviceName');

      await _nearby.startAdvertising(
        deviceName,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );

      await Future.delayed(const Duration(seconds: 1));
    });

    isAdvertising = success;
    if (success) {
      log('Advertising started successfully');
    } else {
      log('Failed to start advertising after $_maxRetries attempts');
    }
    notifyListeners();
  }

  Future<void> startDiscovery() async {
    log('Starting discovery...');

    try {
      // محاولة إيقاف الاكتشاف مباشرة
      await _nearby.stopDiscovery();
      isDiscovering = false;
      discoveredDevices.clear();
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      log('Error stopping existing discovery: $e');
    }

    // Double check permissions
    if (!await checkPermissions()) {
      log('Required permissions not granted');
      return;
    }

    // Try to start discovery with increased delay
    final success = await _retryOperation(() async {
      final deviceName = await _getDeviceName();
      log('Starting discovery with device name: $deviceName');

      await _nearby.startDiscovery(
        deviceName,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (id, name, serviceId) {
          log('Endpoint found: $name ($id)');
          _onEndpointFound(id, name, serviceId);
        },
        onEndpointLost: (id) {
          log('Endpoint lost: $id');
          _onEndpointLost(id!);
        },
      );

      await Future.delayed(const Duration(seconds: 1));
    });

    isDiscovering = success;
    if (success) {
      log('Discovery started successfully');
    } else {
      log('Failed to start discovery after $_maxRetries attempts');
    }
    Future.microtask(() => notifyListeners());
  }

  Future<void> _stopAllServices() async {
    try {
      // إيقاف الإعلان
      if (isAdvertising) {
        await _nearby.stopAdvertising();
        isAdvertising = false;
      }

      // إيقاف الاكتشاف
      if (isDiscovering) {
        await _nearby.stopDiscovery();
        isDiscovering = false;
        discoveredDevices.clear();
      }

      // قطع جميع الاتصالات
      await disconnectFromAllDevices();

      // انتظار لضمان إيقاف جميع الخدمات
      await Future.delayed(const Duration(seconds: 2));

      log('All services stopped successfully');
    } catch (e) {
      log('Error stopping services: $e');
      // Reset states even if there's an error
      isAdvertising = false;
      isDiscovering = false;
      discoveredDevices.clear();
    }
    Future.microtask(() => notifyListeners());
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    log('Processing endpoint found: $name ($id)');
    final device = Device(id: id, name: name);
    if (!discoveredDevices.any((d) => d.id == id)) {
      discoveredDevices.add(device);
      log('Added new device to discovered devices list');
      notifyListeners();
    } else {
      log('Device already in discovered devices list');
    }
  }

  void _onEndpointLost(String id) {
    log('Processing endpoint lost: $id');
    discoveredDevices.removeWhere((device) => device.id == id);
    notifyListeners();
  }

  Future<String> _getMediaDirectory(String type) async {
    final baseDir = Directory(
        '/storage/emulated/0/Android/media/com.example.blutoth_app_wifi');
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    final mediaDir = Directory(path.join(baseDir.path, type));
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    return mediaDir.path;
  }

  String _getMediaType(String? mimeType) {
    if (mimeType?.startsWith('image/') == true) {
      return 'images';
    } else if (mimeType?.startsWith('video/') == true) {
      return 'videos';
    } else if (mimeType?.startsWith('audio/') == true) {
      return 'audio';
    }
    return 'files';
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) async {
    log('Connection initiated with: $id');
    try {
      // تهيئة المجلدات قبل استقبال الملفات
      await _initializeDirectories();

      await _nearby.acceptConnection(
        id,
        onPayLoadRecieved: (endId, payload) async {
          log('Payload received from: $endId');
          try {
            if (payload.type == PayloadType.BYTES) {
              final bytes = payload.bytes!;
              String text = utf8.decode(bytes, allowMalformed: true);

              try {
                final Map<String, dynamic> messageData = jsonDecode(text);
                log('Received message data: $messageData');

                if (messageData['isFile'] == true) {
                  // معالجة metadata الملف
                  final String fileName = messageData['fileName'];
                  final String? mimeType = messageData['mimeType'];
                  final int? fileSize = messageData['fileSize'];
                  final String mediaType = _getMediaType(mimeType);
                  final mediaDir = await _getMediaDirectory(mediaType);

                  // إنشاء المسار النهائي للملف
                  final String finalPath =
                      path.join(mediaDir, 'received_$fileName');

                  // التأكد من وجود المجلد وإنشائه إذا لم يكن موجوداً
                  final directory = Directory(mediaDir);
                  if (!await directory.exists()) {
                    await directory.create(recursive: true);
                  }

                  // تحديد نوع المحتوى المبدئي للرسالة
                  String initialContent;
                  if (mimeType?.startsWith('video/') == true) {
                    initialContent = 'جاري استلام الفيديو... (0%)';
                  } else if (mimeType?.startsWith('audio/') == true) {
                    initialContent = 'جاري استلام المقطع الصوتي... (0%)';
                  } else {
                    initialContent = 'جاري استلام الملف... (0%)';
                  }

                  // إضافة رسالة مؤقتة للملف
                  final message = Message(
                    senderId: endId,
                    content: initialContent,
                    timestamp: DateTime.now(),
                    isFromMe: false,
                    isFile: true,
                    fileName: fileName,
                    filePath: null, // لا نضع المسار حتى يكتمل الحفظ
                    mimeType: mimeType,
                    transferProgress: 0,
                    fileSize: fileSize,
                  );

                  messages.add(message);
                  deviceMessages[endId] = deviceMessages[endId] ?? [];
                  deviceMessages[endId]!.add(message);

                  notifyListeners();
                  await saveMessages();
                  await saveDeviceMessages(endId);
                  log('Added file message: $fileName');
                } else {
                  // معالجة الرسالة النصية
                  final message = Message(
                    senderId: endId,
                    content: messageData['content'],
                    timestamp: DateTime.parse(messageData['timestamp']),
                    isFromMe: false,
                    isFile: false,
                  );

                  messages.add(message);
                  deviceMessages[endId] = deviceMessages[endId] ?? [];
                  deviceMessages[endId]!.add(message);

                  notifyListeners();
                  await saveMessages();
                  await saveDeviceMessages(endId);
                  log('Added text message: ${message.content}');
                }
              } catch (e) {
                // إذا فشل فك الـ JSON، فهذه بيانات الملف
                log('Processing file bytes');

                // البحث عن آخر رسالة ملف في انتظار البيانات
                final pendingMessage = messages.lastWhere(
                  (m) =>
                      m.isFile &&
                      (m.content.startsWith('جاري استلام الفيديو') ||
                          m.content.startsWith('جاري استلام المقطع الصوتي') ||
                          m.content.startsWith('جاري استلام الملف')) &&
                      !m.isFromMe,
                  orElse: () => Message(
                    senderId: endId,
                    content: 'ملف مجهول',
                    timestamp: DateTime.now(),
                    isFromMe: false,
                    isFile: true,
                    fileName: 'unknown_file',
                    filePath: null,
                    mimeType: null,
                  ),
                );

                if (pendingMessage.fileName != null) {
                  // إنشاء مسار مؤقت للملف
                  final tempFileName =
                      'temp_${DateTime.now().millisecondsSinceEpoch}_${pendingMessage.fileName}';
                  final mediaType = _getMediaType(pendingMessage.mimeType);
                  final mediaDir = await _getMediaDirectory(mediaType);
                  final tempFile = File(path.join(mediaDir, tempFileName));

                  try {
                    // التأكد من وجود المجلد
                    final directory = tempFile.parent;
                    if (!await directory.exists()) {
                      await directory.create(recursive: true);
                    }

                    // حفظ الملف في المسار المؤقت
                    await tempFile.writeAsBytes(bytes);
                    log('File saved temporarily to: ${tempFile.path}');

                    // التحقق من وجود الملف وحجمه
                    if (await tempFile.exists()) {
                      final fileSize = await tempFile.length();
                      log('File exists after saving. Size: $fileSize bytes');

                      // التحقق من حجم الملف المتوقع
                      if (pendingMessage.fileSize != null &&
                          fileSize != pendingMessage.fileSize) {
                        throw FileSystemException(
                            'File size mismatch. Expected: ${pendingMessage.fileSize}, Got: $fileSize');
                      }

                      // نقل الملف إلى المسار النهائي
                      final finalFile = File(path.join(
                          mediaDir, 'received_${pendingMessage.fileName}'));
                      await tempFile.rename(finalFile.path);
                      log('File moved to final location: ${finalFile.path}');

                      // تحديث رسالة الملف
                      final index = messages.indexWhere(
                        (m) =>
                            m.isFile &&
                            m.fileName == pendingMessage.fileName &&
                            !m.isFromMe,
                      );

                      if (index != -1) {
                        final message = messages[index];
                        String content;
                        String filePath = finalFile.path;

                        // التأكد من وجود الملف
                        if (!await finalFile.exists()) {
                          throw FileSystemException(
                              'الملف غير موجود في المسار النهائي');
                        }

                        if (message.mimeType?.startsWith('video/') == true) {
                          content = 'فيديو';
                          log('تم حفظ الفيديو في: $filePath');
                        } else if (message.mimeType?.startsWith('audio/') ==
                            true) {
                          content = 'رسالة صوتية';
                          log('تم حفظ المقطع الصوتي في: $filePath');
                        } else {
                          content = 'ملف: ${message.fileName}';
                          log('تم حفظ الملف في: $filePath');
                        }

                        messages[index] = Message(
                          senderId: message.senderId,
                          content: content,
                          timestamp: message.timestamp,
                          isFromMe: false,
                          isFile: true,
                          fileName: message.fileName,
                          filePath: filePath,
                          mimeType: message.mimeType,
                          transferProgress: 1.0,
                          fileSize: fileSize,
                        );

                        // تحديث رسائل الجهاز
                        final deviceIndex = deviceMessages[endId]?.indexWhere(
                          (m) =>
                              m.isFile && m.fileName == pendingMessage.fileName,
                        );

                        if (deviceIndex != null && deviceIndex != -1) {
                          deviceMessages[endId]![deviceIndex] = messages[index];
                        }

                        notifyListeners();
                        await saveMessages();
                        await saveDeviceMessages(endId);
                        log('Updated file message with final path: $filePath');
                      }
                    } else {
                      throw FileSystemException(
                          'File does not exist after saving');
                    }
                  } catch (e) {
                    log('Error saving file: $e');
                    // حذف الملف المؤقت في حالة الفشل
                    if (await tempFile.exists()) {
                      await tempFile.delete();
                    }
                    // تحديث الرسالة لتعكس فشل الحفظ
                    final index = messages.indexWhere(
                      (m) =>
                          m.isFile &&
                          m.fileName == pendingMessage.fileName &&
                          !m.isFromMe,
                    );
                    if (index != -1) {
                      messages[index] = Message(
                        senderId: messages[index].senderId,
                        content: 'فشل في حفظ الملف',
                        timestamp: messages[index].timestamp,
                        isFromMe: false,
                        isFile: true,
                        fileName: messages[index].fileName,
                        filePath: null,
                        mimeType: messages[index].mimeType,
                        transferProgress: 0,
                      );
                      notifyListeners();
                    }
                  }
                }
              }
            }
          } catch (e) {
            log('Error processing payload: $e');
          }
        },
        onPayloadTransferUpdate: (endId, update) async {
          try {
            log('Transfer update - ID: ${update.id}, Status: ${update.status}, Progress: ${update.bytesTransferred}/${update.totalBytes}');

            if (update.status == PayloadStatus.IN_PROGRESS ||
                update.status == PayloadStatus.SUCCESS) {
              final pendingMessage = messages.lastWhere(
                (m) =>
                    m.isFile &&
                    (m.content.startsWith('جاري استلام الفيديو') ||
                        m.content.startsWith('جاري استلام المقطع الصوتي') ||
                        m.content.startsWith('جاري استلام الملف')) &&
                    !m.isFromMe,
                orElse: () => Message(
                  senderId: endId,
                  content: 'ملف مجهول',
                  timestamp: DateTime.now(),
                  isFromMe: false,
                  isFile: true,
                  fileName: 'unknown_file',
                  filePath: null,
                  mimeType: null,
                ),
              );

              if (pendingMessage.fileName != null) {
                final progress = update.bytesTransferred / update.totalBytes;
                fileTransferProgress[pendingMessage.fileName!] = progress;

                // تحديث رسالة التقدم
                final index = messages.indexWhere(
                  (m) =>
                      m.isFile &&
                      m.fileName == pendingMessage.fileName &&
                      !m.isFromMe,
                );

                if (index != -1) {
                  final message = messages[index];
                  String content;
                  String? filePath;

                  if (update.status == PayloadStatus.SUCCESS) {
                    // عند اكتمال النقل، تحديث المحتوى والمسار
                    final mediaType = _getMediaType(message.mimeType);
                    final mediaDir = await _getMediaDirectory(mediaType);
                    filePath =
                        path.join(mediaDir, 'received_${message.fileName}');

                    if (message.mimeType?.startsWith('video/') == true) {
                      content = 'فيديو';
                      log('اكتمل استلام الفيديو: $filePath');
                    } else if (message.mimeType?.startsWith('audio/') == true) {
                      content = 'رسالة صوتية';
                      log('اكتمل استلام المقطع الصوتي: $filePath');
                    } else {
                      content = 'ملف: ${message.fileName}';
                      log('اكتمل استلام الملف: $filePath');
                    }
                  } else {
                    // أثناء النقل، عرض نسبة التقدم
                    if (message.mimeType?.startsWith('video/') == true) {
                      content =
                          'جاري استلام الفيديو... (${(progress * 100).toInt()}%)';
                    } else if (message.mimeType?.startsWith('audio/') == true) {
                      content =
                          'جاري استلام المقطع الصوتي... (${(progress * 100).toInt()}%)';
                    } else {
                      content =
                          'جاري استلام الملف... (${(progress * 100).toInt()}%)';
                    }
                  }

                  messages[index] = Message(
                    senderId: message.senderId,
                    content: content,
                    timestamp: message.timestamp,
                    isFromMe: false,
                    isFile: true,
                    fileName: message.fileName,
                    filePath: filePath,
                    mimeType: message.mimeType,
                    transferProgress: progress,
                    fileSize: message.fileSize,
                  );

                  // تحديث رسائل الجهاز
                  final deviceIndex = deviceMessages[endId]?.indexWhere(
                    (m) => m.isFile && m.fileName == pendingMessage.fileName,
                  );

                  if (deviceIndex != null && deviceIndex != -1) {
                    deviceMessages[endId]![deviceIndex] = messages[index];
                  }

                  notifyListeners();
                  await saveMessages();
                  await saveDeviceMessages(endId);

                  if (update.status == PayloadStatus.SUCCESS) {
                    log('تم تحديث حالة الملف بنجاح: ${message.fileName}');
                  }
                }
              }
            }
          } catch (e) {
            log('Error updating transfer progress: $e');
          }
        },
      );
      log('Connection accepted');
    } catch (e) {
      log('Error in connection initialization: $e');
    }
  }

  void _onConnectionResult(String id, Status status) {
    log('Connection result for $id: $status');
    isConnecting = false;
    currentConnectingDevice = null;

    if (status == Status.CONNECTED) {
      if (!connectedDevices.contains(id)) {
        connectedDevices.add(id);

        // حفظ الجهاز إذا لم يكن موجوداً
        if (!savedDevices.any((d) => d.id == id)) {
          final newDevice = Device(id: id, name: 'User-$id');
          savedDevices.add(newDevice);
          saveDevices();
          loadDeviceMessages(id);
        }

        log('Device added to connected devices list: $id');
      }
    } else {
      log('Connection failed with status: $status');
    }
    notifyListeners();
  }

  void _onDisconnected(String id) {
    log('Device disconnected: $id');
    connectedDevices.remove(id);
    notifyListeners();
  }

  Future<String> _getDeviceName() async {
    final name =
        'User-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';
    log('Generated device name: $name');
    return name;
  }

  Future<void> connectToDevice(String deviceId) async {
    log('Attempting to connect to device: $deviceId');
    isConnecting = true;
    currentConnectingDevice = deviceId;
    notifyListeners();

    final success = await _retryOperation(() async {
      final deviceName = await _getDeviceName();
      await _nearby.requestConnection(
        deviceName,
        deviceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    });

    if (success) {
      log('Connection request sent successfully');
    } else {
      log('Failed to connect after $_maxRetries attempts');
    }

    isConnecting = false;
    currentConnectingDevice = null;
    notifyListeners();
  }

  Future<void> stopAdvertising() async {
    log('Stopping advertising...');
    try {
      await _nearby.stopAdvertising();
      await Future.delayed(const Duration(seconds: 1));
      isAdvertising = false;
      log('Advertising stopped successfully');
      notifyListeners();
    } catch (e) {
      log('Error stopping advertising: $e');
      // Even if there's an error, we should reset the state
      isAdvertising = false;
      notifyListeners();
    }
  }

  Future<void> stopDiscovery() async {
    log('Stopping discovery...');
    try {
      await _nearby.stopDiscovery();
      await Future.delayed(const Duration(seconds: 1));
      isDiscovering = false;
      discoveredDevices.clear();
      log('Discovery stopped successfully');
      notifyListeners();
    } catch (e) {
      log('Error stopping discovery: $e');
      // Even if there's an error, we should reset the state
      isDiscovering = false;
      discoveredDevices.clear();
      notifyListeners();
    }
  }

  Future<void> disconnectFromAllDevices() async {
    log('Disconnecting from all devices...');
    for (String deviceId in connectedDevices) {
      try {
        await _nearby.disconnectFromEndpoint(deviceId);
        log('Disconnected from device: $deviceId');
      } catch (e) {
        log('Error disconnecting from device $deviceId: $e');
      }
    }
    connectedDevices.clear();
    Future.microtask(() => notifyListeners());
  }

  Future<void> sendFile(String deviceId) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: false,
      );

      if (result != null) {
        final String originalPath = result.files.single.path!;
        final int fileSize = await File(originalPath).length();

        // التحقق من حجم الملف (1GB = 1024 * 1024 * 1024 bytes)
        if (fileSize > 1024 * 1024 * 1024) {
          log('File size exceeds limit: ${(fileSize / (1024 * 1024)).toStringAsFixed(2)}MB');
          throw Exception(
              'حجم الملف كبير جداً. الحد الأقصى المسموح به هو 1 جيجابايت');
        }

        log('Selected file path: $originalPath');

        final fileName = path.basename(originalPath);
        final mimeType = lookupMimeType(originalPath);
        final mediaType = _getMediaType(mimeType);

        // إضافة مؤشر تقدم للملف
        fileTransferProgress[fileName] = 0;
        notifyListeners();

        // حفظ الملف في المجلد المناسب
        final mediaDir = await _getMediaDirectory(mediaType);
        final newPath = path.join(mediaDir, 'sent_$fileName');

        // نسخ الملف إلى المجلد الجديد
        await File(originalPath).copy(newPath);
        log('File copied to media directory: $newPath');

        // قراءة محتوى الملف
        final File file = File(newPath);
        final bytes = await file.readAsBytes();

        // إرسال metadata أولاً
        final metaData = {
          'senderId': 'me',
          'content': 'جاري إرسال ملف...',
          'timestamp': DateTime.now().toIso8601String(),
          'isFile': true,
          'isPending': true,
          'fileName': fileName,
          'mimeType': mimeType,
          'fileSize': bytes.length,
        };

        final metaDataJson = jsonEncode(metaData);
        await _nearby.sendBytesPayload(
          deviceId,
          Uint8List.fromList(utf8.encode(metaDataJson)),
        );
        log('Sent file metadata');

        // تحديث نسبة التقدم
        fileTransferProgress[fileName] = 0.1;
        notifyListeners();

        // إرسال محتوى الملف
        await _nearby.sendBytesPayload(deviceId, bytes);
        log('Sent file bytes');

        messages.add(Message(
          senderId: 'me',
          content: mimeType?.startsWith('image/') == true
              ? 'صورة'
              : mimeType?.startsWith('video/') == true
                  ? 'فيديو'
                  : mimeType?.startsWith('audio/') == true
                      ? 'رسالة صوتية'
                      : 'ملف: $fileName',
          timestamp: DateTime.now(),
          isFromMe: true,
          isFile: true,
          fileName: fileName,
          filePath: newPath,
          mimeType: mimeType,
          transferProgress: 1.0,
        ));
        notifyListeners();
        await saveMessages();
        log('File message added to list');
      }
    } catch (e) {
      log('Error sending file: $e');
    }
  }

  Future<void> sendMessage(String deviceId, String message) async {
    try {
      final messageData = {
        'senderId': 'me',
        'content': message,
        'timestamp': DateTime.now().toIso8601String(),
        'isFile': false,
        'fileName': null
      };

      final String jsonMessage = jsonEncode(messageData);
      final bytes = Uint8List.fromList(utf8.encode(jsonMessage));

      await _nearby.sendBytesPayload(deviceId, bytes);

      final newMessage = Message(
        senderId: 'me',
        content: message,
        timestamp: DateTime.now(),
        isFromMe: true,
        isFile: false,
        fileName: null,
      );

      // إضافة الرسالة إلى قائمة رسائل الجهاز
      deviceMessages[deviceId] = deviceMessages[deviceId] ?? [];
      deviceMessages[deviceId]!.add(newMessage);
      messages.add(newMessage);

      notifyListeners();
      await saveDeviceMessages(deviceId);
      log('Message sent and saved for device: $deviceId');
    } catch (e) {
      log('Error sending message: $e');
    }
  }

  Future<void> sendAudioMessage(String deviceId, String audioPath) async {
    try {
      File audioFile = File(audioPath);
      String fileName = path.basename(audioFile.path);
      String? mimeType = lookupMimeType(audioFile.path);

      // إرسال metadata أولاً
      final metaData = {
        'senderId': 'me',
        'content': 'رسالة صوتية',
        'timestamp': DateTime.now().toIso8601String(),
        'isFile': true,
        'isPending': true,
        'fileName': fileName,
        'mimeType': mimeType,
      };

      final metaDataJson = jsonEncode(metaData);
      await _nearby.sendBytesPayload(
        deviceId,
        Uint8List.fromList(utf8.encode(metaDataJson)),
      );
      log('Sent audio metadata');

      // إرسال الملف الصوتي باستخدام sendFilePayload
      await _nearby.sendFilePayload(deviceId, audioFile.path);
      log('Sent audio file');

      messages.add(Message(
        senderId: 'me',
        content: 'رسالة صوتية',
        timestamp: DateTime.now(),
        isFromMe: true,
        isFile: true,
        fileName: fileName,
        filePath: audioFile.path,
        mimeType: mimeType,
      ));
      notifyListeners();
      log('Audio message added to list');
    } catch (e) {
      log('Error sending audio message: $e');
    }
  }

  // دالة جديدة لاسترجاع محادثات جهاز معين
  List<Message> getDeviceMessages(String deviceId) {
    return deviceMessages[deviceId] ?? [];
  }

  @override
  void dispose() {
    // حفظ جميع البيانات عند إغلاق التطبيق
    for (var deviceId in deviceMessages.keys) {
      saveDeviceMessages(deviceId);
    }
    saveDevices();

    log('Disposing ConnectionService...');
    stopAdvertising()
        .then((_) => stopDiscovery())
        .then((_) => disconnectFromAllDevices());
    super.dispose();
  }
}

class Device {
  final String id;
  final String name;

  Device({required this.id, required this.name});
}

class Message {
  final String senderId;
  final String content;
  final DateTime timestamp;
  final bool isFromMe;
  final bool isFile;
  final String? fileName;
  final String? filePath;
  final String? mimeType;
  final double? transferProgress; // إضافة حقل جديد للتقدم
  final int? fileSize;

  Message({
    required this.senderId,
    required this.content,
    required this.timestamp,
    required this.isFromMe,
    this.isFile = false,
    this.fileName,
    this.filePath,
    this.mimeType,
    this.transferProgress,
    this.fileSize,
  });

  Map<String, dynamic> toJson() => {
        'senderId': senderId,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'isFile': isFile,
        'fileName': fileName,
        'filePath': filePath,
        'mimeType': mimeType,
        'transferProgress': transferProgress,
        'fileSize': fileSize,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        senderId: json['senderId'] ?? '',
        content: json['content'] ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'])
            : DateTime.now(),
        isFromMe: false,
        isFile: json['isFile'] ?? false,
        fileName: json['fileName'],
        filePath: json['filePath'],
        mimeType: json['mimeType'],
        transferProgress: json['transferProgress'],
        fileSize: json['fileSize'],
      );
}

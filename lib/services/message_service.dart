import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:mime/mime.dart';

class Message {
  final String senderId;
  final String content;
  final DateTime timestamp;
  final bool isFile;
  final bool isPending;
  final String? fileName;
  final String? filePath;
  final String? mimeType;

  Message({
    required this.senderId,
    required this.content,
    required this.timestamp,
    this.isFile = false,
    this.isPending = false,
    this.fileName,
    this.filePath,
    this.mimeType,
  });

  Map<String, dynamic> toJson() {
    return {
      'senderId': senderId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isFile': isFile,
      'isPending': isPending,
      'fileName': fileName,
      'filePath': filePath,
      'mimeType': mimeType,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      senderId: json['senderId'] ?? '',
      content: json['content'] ?? '',
      timestamp:
          DateTime.parse(json['timestamp'] ?? DateTime.now().toIso8601String()),
      isFile: json['isFile'] ?? false,
      isPending: json['isPending'] ?? false,
      fileName: json['fileName'],
      filePath: json['filePath'],
      mimeType: json['mimeType'],
    );
  }
}

class MessageService extends ChangeNotifier {
  final Nearby _nearby = Nearby();
  final Map<String, List<Message>> _messages = {};
  final Map<String, Map<int, String>> _pendingFiles = {};

  List<Message> getMessages(String deviceId) => _messages[deviceId] ?? [];

  Future<void> sendMessage(String deviceId, String content) async {
    try {
      final message = Message(
        senderId: 'me',
        content: content,
        timestamp: DateTime.now(),
      );

      final Uint8List bytes =
          Uint8List.fromList(utf8.encode(jsonEncode(message.toJson())));
      await _nearby.sendBytesPayload(deviceId, bytes);

      _messages[deviceId] ??= [];
      _messages[deviceId]!.add(message);
      notifyListeners();
      log('Message sent successfully');
    } catch (e) {
      log('Error sending message: $e');
    }
  }

  Future<void> sendFile(String deviceId) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null) {
        File file = File(result.files.single.path!);
        String fileName = result.files.single.name;
        String mimeType =
            lookupMimeType(file.path) ?? 'application/octet-stream';

        // إنشاء مجلد sent_files إذا لم يكن موجوداً
        final appDir = await getApplicationDocumentsDirectory();
        final sentFilesDir = Directory(path.join(appDir.path, 'sent_files'));
        if (!await sentFilesDir.exists()) {
          await sentFilesDir.create(recursive: true);
        }

        // نسخ الملف إلى مجلد sent_files
        final newPath = path.join(sentFilesDir.path, 'sent_$fileName');
        await file.copy(newPath);
        log('File copied to: $newPath');

        // إضافة رسالة "جاري الإرسال"
        final pendingMessage = Message(
          senderId: 'me',
          content: 'جاري إرسال ملف...',
          timestamp: DateTime.now(),
          isFile: true,
          isPending: true,
          fileName: fileName,
          filePath: newPath,
          mimeType: mimeType,
        );

        _messages[deviceId] ??= [];
        _messages[deviceId]!.add(pendingMessage);
        notifyListeners();

        // إرسال metadata
        final metadataBytes = Uint8List.fromList(
            utf8.encode(jsonEncode(pendingMessage.toJson())));
        await _nearby.sendBytesPayload(deviceId, metadataBytes);
        log('Sent file metadata');

        // إرسال الملف
        await _nearby.sendFilePayload(deviceId, newPath);
        log('Sent file payload');

        // تحديث الرسالة بعد اكتمال الإرسال
        final index = _messages[deviceId]!.indexOf(pendingMessage);
        if (index != -1) {
          _messages[deviceId]![index] = Message(
            senderId: 'me',
            content: mimeType.startsWith('image/')
                ? 'صورة'
                : mimeType.startsWith('video/')
                    ? 'فيديو'
                    : mimeType.startsWith('audio/')
                        ? 'رسالة صوتية'
                        : 'ملف: $fileName',
            timestamp: pendingMessage.timestamp,
            isFile: true,
            isPending: false,
            fileName: fileName,
            filePath: newPath,
            mimeType: mimeType,
          );
          notifyListeners();
        }

        log('File sent successfully');
      }
    } catch (e, stackTrace) {
      log('Error sending file: $e\n$stackTrace');
    }
  }

  void handlePayloadReceived(String deviceId, Payload payload) async {
    try {
      if (payload.type == PayloadType.BYTES) {
        final String messageStr =
            utf8.decode(payload.bytes ?? [], allowMalformed: true);
        final Map<String, dynamic> messageData = jsonDecode(messageStr);
        log('Received message data: $messageData');

        final message = Message.fromJson(messageData);

        if (message.isFile) {
          _messages[deviceId] ??= [];
          _messages[deviceId]!.add(message);
          notifyListeners();
          log('File message added: ${message.fileName}');
        } else {
          _messages[deviceId] ??= [];
          _messages[deviceId]!.add(message);
          notifyListeners();
          log('Text message added: ${message.content}');
        }
      } else if (payload.type == PayloadType.FILE) {
        final appDir = await getApplicationDocumentsDirectory();
        final receivedFilesDir =
            Directory(path.join(appDir.path, 'received_files'));
        if (!await receivedFilesDir.exists()) {
          await receivedFilesDir.create(recursive: true);
        }

        final pendingMessage = _messages[deviceId]?.lastWhere(
          (m) => m.isFile && m.isPending,
          orElse: () => Message(
            senderId: deviceId,
            content: 'ملف مجهول',
            timestamp: DateTime.now(),
            isFile: true,
            isPending: true,
            fileName: 'unknown_${payload.id}',
          ),
        );

        final fileName = pendingMessage?.fileName ?? 'unknown_${payload.id}';
        final filePath = path.join(receivedFilesDir.path, fileName);

        _pendingFiles[deviceId] ??= {};
        _pendingFiles[deviceId]![payload.id] = filePath;

        log('File payload will be saved to: $filePath');
      }
    } catch (e, stackTrace) {
      log('Error handling payload: $e\n$stackTrace');
    }
  }

  void handlePayloadTransferUpdate(
      String deviceId, PayloadTransferUpdate update) async {
    try {
      if (update.status == PayloadStatus.SUCCESS &&
          _pendingFiles[deviceId]?.containsKey(update.id) == true) {
        final filePath = _pendingFiles[deviceId]![update.id];
        if (filePath == null) {
          log('No file path found for payload: ${update.id}');
          return;
        }

        final tempFile = File(path.join(
            (await getApplicationDocumentsDirectory()).path,
            update.id.toString()));

        if (await tempFile.exists()) {
          await tempFile.rename(filePath);
          log('File moved to: $filePath');

          final pendingIndex =
              _messages[deviceId]?.indexWhere((m) => m.isFile && m.isPending);

          if (pendingIndex != null && pendingIndex != -1) {
            final pendingMessage = _messages[deviceId]![pendingIndex];
            _messages[deviceId]![pendingIndex] = Message(
              senderId: pendingMessage.senderId,
              content: pendingMessage.content.startsWith('جاري إرسال ملف')
                  ? lookupMimeType(filePath)?.startsWith('image/') == true
                      ? 'صورة'
                      : lookupMimeType(filePath)?.startsWith('video/') == true
                          ? 'فيديو'
                          : lookupMimeType(filePath)?.startsWith('audio/') ==
                                  true
                              ? 'رسالة صوتية'
                              : 'ملف: ${pendingMessage.fileName}'
                  : pendingMessage.content,
              timestamp: pendingMessage.timestamp,
              isFile: true,
              isPending: false,
              fileName: pendingMessage.fileName,
              filePath: filePath,
              mimeType: lookupMimeType(filePath),
            );
            notifyListeners();
            log('Message updated with file: $filePath');
          }

          _pendingFiles[deviceId]?.remove(update.id);
        } else {
          log('Temporary file not found: ${tempFile.path}');
        }
      }
    } catch (e, stackTrace) {
      log('Error handling transfer update: $e\n$stackTrace');
    }
  }

  void clearMessages(String deviceId) {
    _messages.remove(deviceId);
    _pendingFiles.remove(deviceId);
    notifyListeners();
  }

  void clearAllMessages() {
    _messages.clear();
    _pendingFiles.clear();
    notifyListeners();
  }
}

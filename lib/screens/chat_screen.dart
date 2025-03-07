import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import 'package:intl/intl.dart' as intl;
import 'package:open_file/open_file.dart';
import 'package:video_player/video_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mime/mime.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

class ChatScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const ChatScreen({
    Key? key,
    required this.deviceId,
    required this.deviceName,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final AudioRecorder _audioRecorder;
  bool _isRecording = false;
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        final path =
            '${directory.path}/audio_message_${DateTime.now().millisecondsSinceEpoch}.m4a';
        _recordingPath = path;

        await _audioRecorder.start(
          RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: path,
        );

        setState(() {
          _isRecording = true;
        });
      }
    } catch (e) {
      print('Error starting recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
      });

      if (path != null) {
        final service = Provider.of<ConnectionService>(context, listen: false);
        await service.sendAudioMessage(widget.deviceId, path);
      }
    } catch (e) {
      print('Error stopping recording: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.deviceName),
            Consumer<ConnectionService>(
              builder: (context, service, child) {
                final isConnected =
                    service.connectedDevices.contains(widget.deviceId);
                return Text(
                  isConnected ? 'متصل' : 'غير متصل',
                  style: TextStyle(
                    fontSize: 12,
                    color: isConnected ? Colors.green : Colors.red,
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            onPressed: () {
              final service =
                  Provider.of<ConnectionService>(context, listen: false);
              service.sendFile(widget.deviceId);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Consumer<ConnectionService>(
              builder: (context, service, child) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _scrollToBottom());
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: service.messages.length,
                  itemBuilder: (context, index) {
                    final message = service.messages[index];
                    return _MessageBubble(message: message);
                  },
                );
              },
            ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, -2),
            blurRadius: 4,
            color: Colors.black.withOpacity(0.1),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressEnd: (_) => _stopRecording(),
              child: Container(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  _isRecording ? Icons.mic : Icons.mic_none,
                  color: _isRecording
                      ? Colors.red
                      : Theme.of(context).primaryColor,
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: _isRecording ? 'جارٍ التسجيل...' : 'اكتب رسالة...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                enabled: !_isRecording,
              ),
            ),
            const SizedBox(width: 8),
            if (!_isRecording)
              Consumer<ConnectionService>(
                builder: (context, service, child) {
                  return IconButton(
                    onPressed: () {
                      if (_messageController.text.isNotEmpty) {
                        service.sendMessage(
                          widget.deviceId,
                          _messageController.text,
                        );
                        _messageController.clear();
                      }
                    },
                    icon: const Icon(Icons.send),
                    color: Theme.of(context).primaryColor,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatefulWidget {
  final Message message;

  const _MessageBubble({
    Key? key,
    required this.message,
  }) : super(key: key);

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  VideoPlayerController? _videoController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _initializeMedia();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _initializeMedia() async {
    if (widget.message.isFile && widget.message.filePath != null) {
      final mimeType = lookupMimeType(widget.message.filePath!);

      if (mimeType?.startsWith('video/') ?? false) {
        _videoController = VideoPlayerController.file(
          File(widget.message.filePath!),
        );
        await _videoController!.initialize();
        setState(() {});
      } else if (mimeType?.startsWith('audio/') ?? false) {
        await _audioPlayer.setFilePath(widget.message.filePath!);
        _duration = _audioPlayer.duration ?? Duration.zero;
        _audioPlayer.positionStream.listen((position) {
          if (mounted) {
            setState(() => _position = position);
          }
        });
        _audioPlayer.playerStateStream.listen((state) {
          if (mounted) {
            setState(() => _isPlaying = state.playing);
          }
        });
      }
    }
  }

  Widget _buildMediaContent() {
    if (!widget.message.isFile || widget.message.filePath == null) {
      return Text(
        widget.message.content,
        style: TextStyle(
          color: widget.message.isFromMe ? Colors.white : Colors.black,
        ),
        textDirection: TextDirection.rtl,
      );
    }

    if (!File(widget.message.filePath!).existsSync()) {
      return Text(
        'الملف غير موجود: ${widget.message.fileName}',
        style: TextStyle(
          color: widget.message.isFromMe ? Colors.white70 : Colors.black54,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final mimeType = lookupMimeType(widget.message.filePath!);
    final file = File(widget.message.filePath!);

    if (mimeType?.startsWith('image/') ?? false) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(),
                    body: Center(
                      child: InteractiveViewer(
                        child: Image.file(file),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                file,
                fit: BoxFit.cover,
                width: 200,
                height: 200,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    width: 200,
                    height: 200,
                    color: Colors.grey[300],
                    child: Icon(Icons.error),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.message.fileName ?? 'صورة',
            style: TextStyle(
              fontSize: 12,
              color: widget.message.isFromMe ? Colors.white70 : Colors.black54,
            ),
          ),
        ],
      );
    } else if (mimeType?.startsWith('video/') ?? false) {
      if (_videoController?.value.isInitialized ?? false) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                      ),
                      body: Center(
                        child: AspectRatio(
                          aspectRatio: _videoController!.value.aspectRatio,
                          child: VideoPlayer(_videoController!),
                        ),
                      ),
                      floatingActionButton: FloatingActionButton(
                        onPressed: () {
                          setState(() {
                            _videoController!.value.isPlaying
                                ? _videoController!.pause()
                                : _videoController!.play();
                          });
                        },
                        child: Icon(
                          _videoController!.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: Container(
                width: 250,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      ),
                      if (!_videoController!.value.isPlaying)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 50,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 250,
              child: VideoProgressIndicator(
                _videoController!,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                colors: VideoProgressColors(
                  playedColor: widget.message.isFromMe
                      ? Colors.white
                      : Theme.of(context).primaryColor,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.grey[300]!,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.message.fileName ?? 'فيديو',
              style: TextStyle(
                fontSize: 12,
                color:
                    widget.message.isFromMe ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        );
      } else {
        return Center(child: CircularProgressIndicator());
      }
    } else if (mimeType?.startsWith('audio/') ?? false) {
      return Container(
        width: 250,
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: widget.message.isFromMe
                        ? Colors.white
                        : Theme.of(context).primaryColor,
                    size: 40,
                  ),
                  onPressed: () async {
                    if (_isPlaying) {
                      await _audioPlayer.pause();
                    } else {
                      await _audioPlayer.play();
                    }
                    setState(() {});
                  },
                ),
                Expanded(
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: widget.message.isFromMe
                              ? Colors.white
                              : Theme.of(context).primaryColor,
                          inactiveTrackColor: widget.message.isFromMe
                              ? Colors.white24
                              : Colors.grey[300],
                          thumbColor: widget.message.isFromMe
                              ? Colors.white
                              : Theme.of(context).primaryColor,
                          trackHeight: 4,
                          thumbShape:
                              RoundSliderThumbShape(enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value: _position.inSeconds.toDouble(),
                          max: _duration.inSeconds.toDouble(),
                          onChanged: (value) async {
                            final position = Duration(seconds: value.toInt());
                            await _audioPlayer.seek(position);
                            setState(() {
                              _position = position;
                            });
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${_position.inMinutes}:${(_position.inSeconds % 60).toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.message.isFromMe
                                    ? Colors.white70
                                    : Colors.black54,
                              ),
                            ),
                            Text(
                              '${_duration.inMinutes}:${(_duration.inSeconds % 60).toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.message.isFromMe
                                    ? Colors.white70
                                    : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.message.fileName ?? 'رسالة صوتية',
              style: TextStyle(
                fontSize: 12,
                color:
                    widget.message.isFromMe ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () async {
        try {
          final result = await OpenFile.open(widget.message.filePath!);
          if (result.type != ResultType.done) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('لا يمكن فتح الملف: ${result.message}')),
            );
          }
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('حدث خطأ أثناء فتح الملف')),
          );
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.message.isFromMe ? Colors.white30 : Colors.grey[300]!,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file,
              color: widget.message.isFromMe ? Colors.white : Colors.black,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.message.fileName ?? 'ملف غير معروف',
                    style: TextStyle(
                      color:
                          widget.message.isFromMe ? Colors.white : Colors.black,
                      decoration: TextDecoration.underline,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.message.filePath != null)
                    FutureBuilder<FileStat>(
                      future: File(widget.message.filePath!).stat(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          final size = snapshot.data!.size;
                          String fileSize;
                          if (size < 1024) {
                            fileSize = '$size B';
                          } else if (size < 1024 * 1024) {
                            fileSize = '${(size / 1024).toStringAsFixed(1)} KB';
                          } else {
                            fileSize =
                                '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
                          }
                          return Text(
                            fileSize,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.message.isFromMe
                                  ? Colors.white70
                                  : Colors.black54,
                            ),
                          );
                        }
                        return SizedBox();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.message.isFromMe;
    final time = intl.DateFormat('HH:mm').format(widget.message.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: isMe ? Theme.of(context).primaryColor : Colors.grey[300],
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 0),
                  bottomRight: Radius.circular(isMe ? 0 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  _buildMediaContent(),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 12,
                      color: isMe
                          ? Colors.white.withOpacity(0.7)
                          : Colors.black.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera Error: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mobile Stream Cam',
      theme: ThemeData.dark(),
      home: const CameraStreamScreen(),
    );
  }
}

class CameraStreamScreen extends StatefulWidget {
  const CameraStreamScreen({super.key});

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  CameraController? _cameraController;
  StreamController<Uint8List>? _frameStreamController;
  HttpServer? _server;
  
  bool _isStreaming = false;
  bool _isProcessingFrame = false;
  String _ipAddress = 'Fetching IP...';
  String _errorMessage = '';
  final int _port = 8080;
  int _selectedCameraIndex = 0;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _getIPAddress();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera].request();
    _initCamera();
  }

  Future<void> _getIPAddress() async {
    try {
      final info = NetworkInfo();
      String? ip = await info.getWifiIP();
      setState(() {
        _ipAddress = ip ?? '127.0.0.1';
      });
    } catch (e) {
      setState(() {
        _ipAddress = '127.0.0.1';
      });
    }
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) return;

    _cameraController = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = 'Camera Init Error: $e';
      });
    }
  }

  Future<void> _startStreaming() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      setState(() {
        _errorMessage = 'Camera not ready!';
      });
      return;
    }

    setState(() {
      _errorMessage = '';
    });

    try {
      _frameStreamController = StreamController<Uint8List>.broadcast();

      var handler = const Pipeline().addHandler((Request request) async {
        if (request.url.path == 'video') {
          final stream = _frameStreamController!.stream.transform(
            StreamTransformer<Uint8List, List<int>>.fromHandlers(
              handleData: (data, sink) {
                final header = '--boundary\r\n'
                    'Content-Type: image/jpeg\r\n'
                    'Content-Length: ${data.length}\r\n\r\n';
                sink.add(header.codeUnits);
                sink.add(data);
                sink.add('\r\n'.codeUnits);
              },
            ),
          );

          return Response.ok(
            stream,
            headers: {
              'Content-Type': 'multipart/x-mixed-replace; boundary=boundary',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
              'Expires': '0',
              'Connection': 'close',
            },
          );
        }
        return Response.notFound('Not Found');
      });

      // HttpServer വിശ്വസനീയമായ രീതിയിൽ സ്റ്റാറ്റസ് ബൈൻഡ് ചെയ്യുന്നു
      _server = await io.serve(handler, InternetAddress.anyIPv4, _port, shared: true);

      await _cameraController!.startImageStream((CameraImage image) {
        if (_isProcessingFrame || _frameStreamController == null || _frameStreamController!.isClosed) {
          return;
        }
        _isProcessingFrame = true;

        try {
          if (image.planes.isNotEmpty) {
            _frameStreamController!.add(image.planes[0].bytes);
          }
        } catch (e) {
          debugPrint('Frame Stream Error: $e');
        } finally {
          _isProcessingFrame = false;
        }
      });

      setState(() {
        _isStreaming = true;
      });
    } catch (e) {
      await _stopStreaming();
      setState(() {
        _isStreaming = false;
        _errorMessage = 'Server Error: $e';
      });
    }
  }

  Future<void> _stopStreaming() async {
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        await _cameraController?.stopImageStream();
      }
    } catch (_) {}

    try {
      await _frameStreamController?.close();
    } catch (_) {}

    try {
      if (_server != null) {
        await _server?.close(force: true);
        _server = null;
      }
    } catch (_) {}

    setState(() {
      _isStreaming = false;
    });
  }

  void _switchCamera() async {
    if (_cameras.length < 2) return;
    if (_isStreaming) await _stopStreaming();

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _initCamera();
  }

  @override
  void dispose() {
    _stopStreaming();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile Stream Cam'),
        actions: [
          IconButton(
            icon: const Icon(Icons.switch_camera),
            onPressed: _switchCamera,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _getIPAddress,
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? CameraPreview(_cameraController!)
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.black87,
            child: Column(
              children: [
                if (_errorMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Text(
                      _errorMessage,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                SelectableText(
                  _isStreaming
                      ? 'Wi-Fi URL: http://$_ipAddress:$_port/video'
                      : 'Press Start to Stream',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.greenAccent,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'USB / ADB URL: http://localhost:$_port/video',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isStreaming ? Colors.red : Colors.green,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
                  label: Text(_isStreaming ? 'STOP STREAMING' : 'START STREAMING'),
                  onPressed: () {
                    if (_isStreaming) {
                      _stopStreaming();
                    } else {
                      _startStreaming();
                    }
                  },
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}

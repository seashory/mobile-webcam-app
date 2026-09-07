import 'dart:async';
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
  StreamController<List<int>>? _frameStreamController;
  dynamic _server; // IOServer-ന് പകരം dynamic നൽകിയപ്പോൾ Type mismatch പരിഹരിക്കപ്പെട്ടു
  
  bool _isStreaming = false;
  String _ipAddress = 'Fetching IP...';
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
    final info = NetworkInfo();
    String? ip = await info.getWifiIP();
    setState(() {
      _ipAddress = ip ?? '127.0.0.1 (USB Active)';
    });
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) return;

    _cameraController = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _startStreaming() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    _frameStreamController = StreamController<List<int>>.broadcast();

    var handler = const Pipeline().addHandler((Request request) {
      if (request.url.path == 'video') {
        return Response.ok(
          _frameStreamController!.stream.map((frame) {
            return [
              '--boundary\r\n',
              'Content-Type: image/jpeg\r\n',
              'Content-Length: ${frame.length}\r\n\r\n',
              ...frame,
              '\r\n'
            ];
          }).transform(StreamTransformer.fromHandlers(handleData: (data, sink) {
            for (var item in data) {
              sink.add(item as List<int>);
            }
          })),
          headers: {
            'Content-Type': 'multipart/x-mixed-replace; boundary=boundary',
            'Cache-Control': 'no-cache',
            'Connection': 'close',
          },
        );
      }
      return Response.notFound('Not Found');
    });

    _server = await io.serve(handler, '0.0.0.0', _port);

    _cameraController!.startImageStream((CameraImage image) {
      if (_frameStreamController != null && !_frameStreamController!.isClosed) {
        Uint8List bytes = image.planes[0].bytes;
        _frameStreamController!.add(bytes);
      }
    });

    setState(() {
      _isStreaming = true;
    });
  }

  Future<void> _stopStreaming() async {
    await _cameraController?.stopImageStream();
    await _frameStreamController?.close();
    
    if (_server != null) {
      try {
        await _server.close(force: true);
      } catch (_) {
        await _server.close();
      }
    }

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

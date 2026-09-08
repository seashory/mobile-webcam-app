import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

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
    } catch (_) {
      setState(() {
        _ipAddress = '127.0.0.1';
      });
    }
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) return;

    _cameraController = CameraController(
      _cameras[0],
      ResolutionPreset.low,
      enableAudio: false,
    );

    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  Uint8List _convertYUV420ToJpeg(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    var imgImage = img.Image(width: width, height: height);

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yPlane.bytesPerRow + x;
        final int uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * uPlane.bytesPerPixel!;

        final int yValue = yPlane.bytes[yIndex];
        final int uValue = uPlane.bytes[uvIndex];
        final int vValue = vPlane.bytes[uvIndex];

        int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(0, 255);
        int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128)).round().clamp(0, 255);
        int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(0, 255);

        imgImage.setPixelRgb(x, y, r, g, b);
      }
    }
    return Uint8List.fromList(img.encodeJpg(imgImage, quality: 50));
  }

  Future<void> _startStreaming() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    setState(() {
      _errorMessage = '';
    });

    try {
      _frameStreamController = StreamController<Uint8List>.broadcast();

      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      
      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/video') {
          request.response.headers.set('Content-Type', 'multipart/x-mixed-replace; boundary=frame');
          request.response.headers.set('Cache-Control', 'no-cache');

          await for (Uint8List frame in _frameStreamController!.stream) {
            try {
              request.response.write('--frame\r\n');
              request.response.write('Content-Type: image/jpeg\r\n');
              request.response.write('Content-Length: ${frame.length}\r\n\r\n');
              request.response.add(frame);
              request.response.write('\r\n');
              await request.response.flush();
            } catch (_) {
              break;
            }
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('Not Found');
          await request.response.close();
        }
      });

      _cameraController!.startImageStream((CameraImage image) async {
        if (_isProcessingFrame) return;
        _isProcessingFrame = true;

        try {
          if (_frameStreamController != null && !_frameStreamController!.isClosed) {
            Uint8List jpegBytes = _convertYUV420ToJpeg(image);
            _frameStreamController!.add(jpegBytes);
          }
        } catch (_) {}

        _isProcessingFrame = false;
      });

      setState(() {
        _isStreaming = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Server Error: $e';
        _isStreaming = false;
      });
    }
  }

  Future<void> _stopStreaming() async {
    try {
      await _cameraController?.stopImageStream();
      await _frameStreamController?.close();
      await _server?.close(force: true);
    } catch (_) {}

    setState(() {
      _isStreaming = false;
    });
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
      appBar: AppBar(title: const Text('Mobile Stream Cam')),
      body: Column(
        children: [
          Expanded(
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? CameraPreview(_cameraController!)
                : const Center(child: CircularProgressIndicator()),
          ),
          if (_errorMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(_errorMessage, style: const TextStyle(color: Colors.redAccent)),
            ),
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.black87,
            child: Column(
              children: [
                SelectableText(
                  _isStreaming
                      ? 'Wi-Fi: http://$_ipAddress:$_port/video\nUSB: http://localhost:$_port/video'
                      : 'Press Start to Stream',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.greenAccent),
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

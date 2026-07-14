import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GPSIphoneApp());
}

class GPSIphoneApp extends StatelessWidget {
  const GPSIphoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPS Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const GPSTrackerPage(),
    );
  }
}

class GPSTrackerPage extends StatefulWidget {
  const GPSTrackerPage({super.key});

  @override
  State<GPSTrackerPage> createState() => _GPSTrackerPageState();
}

class _GPSTrackerPageState extends State<GPSTrackerPage> {
  static const String _serverUrl = 'http://152.136.119.155/server_gps.php';

  bool _isTracking = false;
  String _status = '就绪，等待开始';
  String _deviceId = 'unknown';
  String _platform = 'unknown';
  String _model = 'unknown';
  Position? _lastPosition;
  StreamSubscription<Position>? _positionStream;
  int _uploadCount = 0;
  int _failCount = 0;

  // 上传间隔（秒）
  Duration _uploadInterval = const Duration(seconds: 5);
  DateTime? _lastUploadTime;

  @override
  void initState() {
    super.initState();
    _getDeviceId();
  }

  Future<void> _getDeviceId() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _deviceId = iosInfo.identifierForVendor ?? 'ios_unknown';
        _platform = 'ios';
        _model = iosInfo.model;
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _deviceId = androidInfo.id;
        _platform = 'android';
        _model = '${androidInfo.brand} ${androidInfo.model}';
      } else {
        _deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
      }
      setState(() {});
    } catch (e) {
      _deviceId = 'flutter_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  @override
  void dispose() {
    _stopTracking();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    // 先请求定位权限
    var locationPermission = await Permission.location.request();
    if (locationPermission.isDenied || locationPermission.isPermanentlyDenied) {
      // 请求精确位置（iOS 14+）
      locationPermission = await Permission.locationWhenInUse.request();
    }

    if (locationPermission.isGranted || locationPermission.isLimited) {
      // 检查 GPS 服务是否开启
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _status = '请开启 GPS 定位服务');
        return false;
      }
      return true;
    } else if (locationPermission.isPermanentlyDenied) {
      setState(() => _status = '定位权限被永久拒绝，请在设置中开启');
      // 引导用户去设置
      if (mounted) {
        _showPermissionDialog();
      }
      return false;
    }
    return false;
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要定位权限'),
        content: const Text('请在系统设置中允许此应用访问位置信息'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('去设置'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _startTracking() async {
    final hasPermission = await _requestPermissions();
    if (!hasPermission) return;

    setState(() {
      _isTracking = true;
      _status = '正在获取 GPS...';
      _uploadCount = 0;
      _failCount = 0;
      _lastUploadTime = null;
    });

    // 定位设置：高精度，每5秒更新一次，最小位移0米（每次都更新）
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      timeLimit: null,
    );

    _positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings)
            .listen(
      (Position position) {
        _lastPosition = position;
        // 限制上传频率
        final now = DateTime.now();
        if (_lastUploadTime == null ||
            now.difference(_lastUploadTime!) >= _uploadInterval) {
          _lastUploadTime = now;
          _uploadPosition(position);
        }
        if (mounted) {
          setState(() {});
        }
      },
      onError: (error) {
        setState(() => _status = '定位错误: $error');
      },
    );

    setState(() => _status = 'GPS 追踪已启动，每${_uploadInterval.inSeconds}秒上传');
  }

  Future<void> _uploadPosition(Position position) async {
    try {
      final body = {
        'ID': _deviceId,
        'Time': DateTime.now().millisecondsSinceEpoch.toString(),
        'Lat': position.latitude.toStringAsFixed(8),
        'Lon': position.longitude.toStringAsFixed(8),
        'Alt': ' ${position.altitude.toStringAsFixed(0)}',
        'Speed': '${position.speed.toStringAsFixed(2)} m/s ',
      };

      final response = await http
          .post(
            Uri.parse(_serverUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      setState(() {
        _uploadCount++;
        if (response.statusCode == 200) {
          _status =
              'GPS 追踪中 | 成功: $_uploadCount | 失败: $_failCount';
        } else {
          _failCount++;
          _status =
              '服务器返回 ${response.statusCode} | 成功: $_uploadCount | 失败: $_failCount';
        }
      });
    } catch (e) {
      setState(() {
        _failCount++;
        _status =
            '上传失败: $e | 成功: $_uploadCount | 失败: $_failCount';
      });
    }
  }

  void _stopTracking() {
    _positionStream?.cancel();
    _positionStream = null;
    setState(() {
      _isTracking = false;
      _status = '追踪已停止';
    });
  }

  String _formatSpeed(double? speed) {
    if (speed == null || speed < 0) return 'N/A';
    // speed 为 m/s，转为 km/h
    final kmh = speed * 3.6;
    return '${kmh.toStringAsFixed(1)} km/h';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS Tracker'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ----- 状态卡片 -----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isTracking ? Icons.location_on : Icons.location_off,
                          color: _isTracking ? Colors.green : Colors.grey,
                          size: 28,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isTracking ? '追踪中' : '已停止',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      style: TextStyle(
                        fontSize: 13,
                        color: _isTracking
                            ? Colors.green.shade300
                            : Colors.grey.shade400,
                      ),
                    ),
                    const Divider(height: 20),
                    _buildInfoRow('设备 ID', _deviceId),
                    _buildInfoRow('上传间隔', '${_uploadInterval.inSeconds} 秒'),
                    _buildInfoRow('服务器', _serverUrl),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- 实时 GPS 数据卡片 -----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '实时 GPS 数据',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    _buildGPSRow('纬度 (Latitude)',
                        _lastPosition?.latitude.toStringAsFixed(6) ?? '--'),
                    _buildGPSRow('经度 (Longitude)',
                        _lastPosition?.longitude.toStringAsFixed(6) ?? '--'),
                    _buildGPSRow(
                        '海拔 (Altitude)', '${_lastPosition?.altitude.toStringAsFixed(1) ?? '--'} m'),
                    _buildGPSRow('精度 (Accuracy)',
                        '${_lastPosition?.accuracy.toStringAsFixed(1) ?? '--'} m'),
                    _buildGPSRow('速度 (Speed)',
                        _formatSpeed(_lastPosition?.speed)),
                    _buildGPSRow('方向 (Heading)',
                        _lastPosition?.heading?.toStringAsFixed(1) ?? '--'),
                    _buildGPSRow(
                        '定位时间',
                        _lastPosition?.timestamp
                                ?.toLocal()
                                .toString()
                                .substring(0, 19) ??
                            '--'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- 统计数据卡片 -----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '上传统计',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatItem(
                            '成功', _uploadCount, Colors.greenAccent),
                        _buildStatItem('失败', _failCount, Colors.redAccent),
                        _buildStatItem('总计', _uploadCount + _failCount,
                            Colors.blueAccent),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ----- 控制按钮 -----
            SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _isTracking ? _stopTracking : _startTracking,
                icon: Icon(_isTracking ? Icons.stop : Icons.play_arrow,
                    size: 28),
                label: Text(
                  _isTracking ? '停止追踪' : '开始追踪',
                  style: const TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _isTracking ? Colors.red.shade700 : Colors.green.shade700,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- 间隔调节 -----
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Text('上传间隔:'),
                    Expanded(
                      child: Slider(
                        value: _uploadInterval.inSeconds.toDouble(),
                        min: 1,
                        max: 30,
                        divisions: 29,
                        label: '${_uploadInterval.inSeconds} 秒',
                        onChanged: _isTracking
                            ? null
                            : (val) {
                                setState(() {
                                  _uploadInterval =
                                      Duration(seconds: val.round());
                                });
                              },
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${_uploadInterval.inSeconds}s',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              '提示：追踪开始后无法调整间隔',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              '$label:',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGPSRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          Text(
            value,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: TextStyle(color: Colors.grey.shade400)),
      ],
    );
  }
}

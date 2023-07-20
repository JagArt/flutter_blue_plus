// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: avoid_print

part of flutter_blue_plus;

class FlutterBluePlus {
  static final FlutterBluePlus _instance = FlutterBluePlus._();
  static FlutterBluePlus get instance => _instance;

  final MethodChannel _channel = const MethodChannel('flutter_blue_plus/methods');
  final EventChannel _stateChannel = const EventChannel('flutter_blue_plus/state');
  final StreamController<MethodCall> _methodStreamController = StreamController.broadcast(); // ignore: close_sinks

  final _BehaviorSubject<bool> _isScanning = _BehaviorSubject(false);

  final _BehaviorSubject<List<ScanResult>> _scanResults = _BehaviorSubject([]);

  // timeout for scanning that can be cancelled by stopScan
  Timer? _scanTimeout;

  // BufferStream for scanning that can be closed by stopScan
  _BufferStream<ScanResult>? _scanResultsBuffer;

  /// Log level of the instance, default is all messages (debug).
  LogLevel _logLevel = LogLevel.debug;

  /// Cached broadcast stream for FlutterBlue.state events
  /// Caching this stream allows for more than one listener to subscribe
  /// and unsubscribe apart from each other,
  /// while allowing events to still be sent to others that are subscribed
  Stream<BluetoothAdapterState>? _adapterStateStream;

  /// Singleton boilerplate
  FlutterBluePlus._() {
    _channel.setMethodCallHandler((MethodCall call) async {
      _methodStreamController.add(call);
    });

    setLogLevel(logLevel);
  }

  // Used internally to dispatch methods from platform.
  Stream<MethodCall> get _methodStream => _methodStreamController.stream;

  LogLevel get logLevel => _logLevel;

  /// Checks whether the device supports Bluetooth
  Future<bool> get isAvailable => _channel.invokeMethod('isAvailable').then<bool>((d) => d);

  @Deprecated('Use adapterName instead')
  Future<String> get name => adapterName;

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  Future<String> get adapterName => _channel.invokeMethod('getAdapterName').then<String>((d) => d);

  /// Checks if Bluetooth functionality is turned on
  Future<bool> get isOn => _channel.invokeMethod('isOn').then<bool>((d) => d);

  Stream<bool> get isScanning => _isScanning.stream;

  bool get isScanningNow => _isScanning.latestValue;

  /// Tries to turn on Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned on.
  /// You have to listen for a stateChange to ON to ensure bluetooth is already running
  ///
  /// Returns false if an error occured or bluetooth is already running
  ///
  Future<bool> turnOn() {
    return _channel.invokeMethod('turnOn').then<bool>((d) => d);
  }

  /// Tries to turn off Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned off.
  /// You have to listen for a stateChange to OFF to ensure bluetooth is turned off
  ///
  /// Returns false if an error occured
  ///
  Future<bool> turnOff() {
    return _channel.invokeMethod('turnOff').then<bool>((d) => d);
  }

  /// Returns a stream that is a list of [ScanResult] results while a scan is in progress.
  ///
  /// The list emitted is all the scanned results as of the last initiated scan. When a scan is
  /// first started, an empty list is emitted. The returned stream is never closed.
  ///
  /// One use for [scanResults] is as the stream in a StreamBuilder to display the
  /// results of a scan in real time while the scan is in progress.
  Stream<List<ScanResult>> get scanResults => _scanResults.stream;

  @Deprecated('Use adapterState instead')
  Stream<BluetoothAdapterState> get state async* {
    yield* adapterState;
  }

  /// Gets the current state of the Bluetooth module
  Stream<BluetoothAdapterState> get adapterState async* {
    BluetoothAdapterState initialState = await _channel
        .invokeMethod('getAdapterState')
        .then((buffer) => BmBluetoothAdapterState.fromMap(buffer))
        .then((s) => bmToBluetoothAdapterState(s.adapterState));

    yield initialState;

    _adapterStateStream ??= _stateChannel
        .receiveBroadcastStream()
        .map((buffer) => BmBluetoothAdapterState.fromMap(buffer))
        .map((s) => bmToBluetoothAdapterState(s.adapterState))
        .doOnCancel(() => _adapterStateStream = null);

    yield* _adapterStateStream!;
  }

  /// Retrieve a list of connected devices
  Future<List<BluetoothDevice>> get connectedDevices {
    return _channel
        .invokeMethod('getConnectedDevices')
        .then((buffer) => BmConnectedDevicesResponse.fromMap(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Retrieve a list of bonded devices (Android only)
  Future<List<BluetoothDevice>> get bondedDevices {
    return _channel
        .invokeMethod('getBondedDevices')
        .then((buffer) => BmConnectedDevicesResponse.fromMap(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Starts a scan for Bluetooth Low Energy devices and returns a stream
  /// of the [ScanResult] results as they are received.
  ///
  /// timeout calls stopStream after a specified [Duration].
  /// You can also get a list of ongoing results in the [scanResults] stream.
  /// If scanning is already in progress, this will throw an [Exception].
  ///
  /// set [androidUsesFineLocation] to true if you want to derive the physical location of the device
  /// on Android Version >=31 (Android 12). You need to add the following permission to your AndroidManifest.xml:
  /// <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
  Stream<ScanResult> scan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<Guid> withDevices = const [],
    List<String> macAddresses = const [],
    Duration? timeout,
    bool allowDuplicates = false,
    bool androidUsesFineLocation = false,
  }) async* {
    var settings = BmScanSettings(
        serviceUuids: withServices.map((g) => g.toString()).toList(),
        macAddresses: macAddresses,
        allowDuplicates: allowDuplicates,
        androidScanMode: scanMode.value,
        androidUsesFineLocation: androidUsesFineLocation);

    if (_isScanning.value == true) {
      throw Exception('Another scan is already in progress.');
    }

    // push to isScanning stream
    _isScanning.add(true);

    // Clear scan results list
    _scanResults.add(<ScanResult>[]);

    Stream<ScanResult> scanResultsStream = FlutterBluePlus.instance._methodStream
        .where((m) => m.method == "ScanResult")
        .map((m) => m.arguments)
        .map((buffer) => BmScanResult.fromMap(buffer))
        .map((p) => ScanResult.fromProto(p))
        .takeWhile((element) => _isScanning.value)
        .doOnDone(stopScan);

    // Start listening now, before invokeMethod, to ensure we don't miss any results
    _scanResultsBuffer = _BufferStream.listen(scanResultsStream);

    // Start timer *after* stream is being listened to, to make sure we don't miss the timeout
    if (timeout != null) {
      _scanTimeout = Timer(timeout, () {
        _scanResultsBuffer?.close();
        _isScanning.add(false);
        _channel.invokeMethod('stopScan');
      });
    }

    try {
      await _channel.invokeMethod('startScan', settings.toMap());
    } catch (e) {
      print('Error starting scan.');
      _isScanning.add(false);
      rethrow;
    }

    await for (ScanResult item in _scanResultsBuffer!.stream) {
      // update list of devices
      List<ScanResult> list = List<ScanResult>.from(_scanResults.value);
      if (list.contains(item)) {
        int index = list.indexOf(item);
        list[index] = item;
      } else {
        list.add(item);
      }

      _scanResults.add(list);

      yield item;
    }
  }

  /// Starts a scan and returns a future that will complete once the scan has finished.
  ///
  /// Once a scan is started, call [stopScan] to stop the scan and complete the returned future.
  ///
  /// timeout automatically stops the scan after a specified [Duration].
  ///
  /// To observe the results while the scan is in progress, listen to the [scanResults] stream,
  /// or call [scan] instead.
  ///
  /// set [androidUsesFineLocation] to true if you want to derive the physical location of the device
  /// on Android Version >=31 (Android 12). You need to add the following permission to your AndroidManifest.xml:
  /// <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
  Future startScan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<Guid> withDevices = const [],
    List<String> macAddresses = const [],
    Duration? timeout,
    bool allowDuplicates = false,
    bool androidUsesFineLocation = false,
  }) async {
    await scan(
            scanMode: scanMode,
            withServices: withServices,
            withDevices: withDevices,
            macAddresses: macAddresses,
            timeout: timeout,
            allowDuplicates: allowDuplicates,
            androidUsesFineLocation: androidUsesFineLocation)
        .drain();
    return _scanResults.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
    await _channel.invokeMethod('stopScan');
    _scanResultsBuffer?.close();
    _scanTimeout?.cancel();
    _isScanning.add(false);
  }

  /// The list of connected peripherals can include those that are connected
  /// by other apps and that will need to be connected locally using the
  /// device.connect() method before they can be used.
  //      Stream<List<BluetoothDevice>> connectedDevices({
  //            List<Guid> withServices = const [],
  //      }) =>
  //                  throw UnimplementedError();

  /// Sets the log level of the FlutterBlue instance
  /// Messages equal or below the log level specified are stored/forwarded,
  /// messages above are dropped.
  void setLogLevel(LogLevel level) async {
    await _channel.invokeMethod('setLogLevel', level.index);
    _logLevel = level;
  }

  void _log(LogLevel level, String message) {
    if (level.index <= _logLevel.index) {
      if (kDebugMode) {
        print(message);
      }
    }
  }
}

/// Log levels for FlutterBlue
enum LogLevel {
  emergency, // 0
  alert, // 1
  critical, // 2
  error, // 3
  warning, // 4
  notice, // 5
  info, // 6
  debug, // 7
}

/// State of the bluetooth adapter.
enum BluetoothAdapterState { unknown, unavailable, unauthorized, turningOn, on, turningOff, off }

BluetoothAdapterState bmToBluetoothAdapterState(BmAdapterStateEnum value) {
  switch (value) {
    case BmAdapterStateEnum.unknown:
      return BluetoothAdapterState.unknown;
    case BmAdapterStateEnum.unavailable:
      return BluetoothAdapterState.unavailable;
    case BmAdapterStateEnum.unauthorized:
      return BluetoothAdapterState.unauthorized;
    case BmAdapterStateEnum.turningOn:
      return BluetoothAdapterState.turningOn;
    case BmAdapterStateEnum.on:
      return BluetoothAdapterState.on;
    case BmAdapterStateEnum.turningOff:
      return BluetoothAdapterState.turningOff;
    case BmAdapterStateEnum.off:
      return BluetoothAdapterState.off;
  }
}

class ScanMode {
  const ScanMode(this.value);
  static const lowPower = ScanMode(0);
  static const balanced = ScanMode(1);
  static const lowLatency = ScanMode(2);
  static const opportunistic = ScanMode(-1);
  final int value;
}

class DeviceIdentifier {
  final String id;
  const DeviceIdentifier(this.id);

  @override
  String toString() => id;

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(other) => other is DeviceIdentifier && _compareAsciiLowerCase(id, other.id) == 0;
}

class ScanResult {
  ScanResult.fromProto(BmScanResult p)
      : device = BluetoothDevice.fromProto(p.device),
        advertisementData = AdvertisementData.fromProto(p.advertisementData),
        rssi = p.rssi,
        timeStamp = DateTime.now();

  final BluetoothDevice device;
  final AdvertisementData advertisementData;
  final int rssi;
  final DateTime timeStamp;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && runtimeType == other.runtimeType && device == other.device;

  @override
  int get hashCode => device.hashCode;

  @override
  String toString() {
    return 'ScanResult{'
        'device: $device, '
        'advertisementData: $advertisementData, '
        'rssi: $rssi, '
        'timeStamp: $timeStamp'
        '}';
  }
}

class AdvertisementData {
  final String localName;
  final int? txPowerLevel;
  final bool connectable;
  final Map<int, List<int>> manufacturerData;
  final Map<String, List<int>> serviceData;
  final List<String> serviceUuids;

  AdvertisementData.fromProto(BmAdvertisementData p)
      : localName = p.localName,
        txPowerLevel = p.txPowerLevel,
        connectable = p.connectable,
        manufacturerData = p.manufacturerData,
        serviceData = p.serviceData,
        serviceUuids = p.serviceUuids;

  @override
  String toString() {
    return 'AdvertisementData{'
        'localName: $localName, '
        'txPowerLevel: $txPowerLevel, '
        'connectable: $connectable, '
        'manufacturerData: $manufacturerData, '
        'serviceData: $serviceData, '
        'serviceUuids: $serviceUuids'
        '}';
  }
}

class FlutterBluePlusException implements Exception {
  final String errorName;
  final int? errorCode;
  final String? errorString;

  FlutterBluePlusException(this.errorName, this.errorCode, this.errorString);

  @override
  String toString() {
    return 'FlutterBluePlusException: name:$errorName errorCode:$errorCode, errorString:$errorString';
  }
}

// bluetooth_connectivity.dart
import 'package:flutter/services.dart';
import 'package:self_science_station/sensor/sensorInstance.dart';
import 'package:self_science_station/utils/muse/ble/ble_manager.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';  
import 'package:flutter_uxcam/flutter_uxcam.dart';
import 'package:self_science_station/utils/muse/utils/constants.dart';
import 'package:self_science_station/utils/muse/utils/file_system.dart';
import 'package:self_science_station/utils/muse/utils/types.dart';
import 'package:uuid/uuid.dart';
import 'dart:developer' as dev;
import 'dart:math';

class MuseSDK extends SensorInstance {
  final identifier;
  final museName;
  late final BleManager muse;
  late final Storage fileHandler;
  BluetoothDevice? deviceHandler;
  final logs = ['Service started'];

  bool streamsStarted = false;
  bool sessionStarted = false;

  Function(EEGEpoch)? onEEGEpochUpdatedCallback;
  Function(EEGEpoch)? onPPGEpochUpdatedCallback;
  Function(EEGEpoch)? onAccelEpochUpdatedCallback;
  Function(EEGEpoch)? onGyroEpochUpdatedCallback;

  // Constructor
  MuseSDK(super.sp, super.sInstance, super.sType, this.identifier, this.museName){
      fileHandler = Storage(identifier); 
      muse = BleManager(fileHandler);
      initState();
    }

  
  // Init
  void initState() async {
    muse.listenToConnectionChanges();

    // Listen to battery level
    muse.teleStream.listen((onData) {
      print("The battery level: $onData");
      if (onData < 30.0) {
        FlutterUxcam.logEventWithProperties('lowBatteryMuse',
                  {'Battery level': onData, 'device': identifier});
      }
      if (onData < 2) {
        sState.availabilityState = SensorAvailabilityState.faulty;
      }
    });

    // Listen to connection state
    muse.connectionStateStream.listen((event) async {
      if(event.connectionState == BluetoothConnectionState.connected) {
        dev.log("Device: ${event.device.platformName}, identifier: $identifier");
        if (event.device.platformName == identifier) {
          // Assign the device to the instance deviceHandler variable once connected, so that same device is used to stop streaming, recording, etc
          deviceHandler = event.device;
          
          print("CONNECTED MUSE EVENT");
          FlutterUxcam.logEventWithProperties(
              'connectedMuse', {'device': identifier});
          onConnected();
          //connectedDevices.add(event.device.remoteId);
          await muse.setup(event.device);
          //await startStreaming(event.device);
          
        }
        else {
          print("Couldn't recognice device ID of connected event");
        }
      }
      if(event.connectionState == BluetoothConnectionState.disconnected) {
        dev.log("Device: ${event.device.platformName}, identifier: $identifier");
        if (event.device.platformName == identifier) {
          //connectedDevices.remove(event.device.remoteId);
          //streamsStarted.remove(event.device.remoteId); // Reset stream started status

          print("DISCONNECTED MUSE EVENT");
          FlutterUxcam.logEventWithProperties(
              'disconnectedMuse', {'device': identifier});
          sState.availabilityState = SensorAvailabilityState.available;
          onDisconnected();
        }
        else {
          print("Couldn't recognice device ID of disconnected event");
        }
      }
    });


  }

  @override
  Future<bool> connectSensor() async {
    print('Connecting to device: $identifier');
    FlutterUxcam.logEventWithProperties('connectRequestMuse', {'device': identifier});

    final completer = Completer<BluetoothDevice>();
    late StreamSubscription<List<ScanResult>> subscription;

    try {
      // Start scanning for the sensor and handle the device found callback
      subscription = scanForSensor((device) {
        if (device.platformName == identifier && !completer.isCompleted) {
          completer.complete(device);
        }
      });

      // Wait for the device to be found
      BluetoothDevice device = await completer.future;

      // Connect to the device
      await muse.connect(device, (DeviceIdentifier deviceId) {
        print("Connected to ${device.platformName}");
        sState.connectionState = SensorConnectionState.connected;
      });

      return true;
    } catch (e) {
      print('Failed to connect device $identifier: ${e.toString()}');
      return false;
    } finally {
      // Cancel the subscription after completing or error
      await subscription.cancel();
    }
  }

  @override
  void connectSensorWithTimeout({required timeout, Function? connectionCallback}) async {
    print("Connecting sensor $identifier with timeout $timeout");

    final completer = Completer<BluetoothDevice>();
    late StreamSubscription<List<ScanResult>> subscription;

    try {
      // Start scanning for the sensor and handle the device found callback
      subscription = scanForSensor((device) {
        if (device.platformName == identifier && !completer.isCompleted) {
          completer.complete(device);
        }
      });

      // Wait for the device to be found, or timeout
      BluetoothDevice device = await completer.future.timeout(timeout, onTimeout: () {
        throw TimeoutException("Connection timeout reached");
      });

      // Connect to the device
      await muse.connect(device, (DeviceIdentifier deviceId) {
        print("Connected to ${device.platformName} with ID: $deviceId");
        sState.connectionState = SensorConnectionState.connected;
        if (connectionCallback != null) {
          connectionCallback(true); // Indicate success
        }
      });
    } catch (e) {
      print('Failed to connect device $identifier: ${e.toString()}');
      if (e is TimeoutException) {
        print("Connection timeout reached. Bailing.");
        FlutterUxcam.logEventWithProperties('connectionTimedOutMuse', {'device': identifier});
      }
      if (connectionCallback != null) {
        connectionCallback(false); // Indicate failure
      }
    } finally {
      // Cancel the subscription after completing or error
      await subscription.cancel();
    }
  }


  @override
  Future<bool> disconnectSensor() async {
    FlutterUxcam.logEventWithProperties(
        'disconnectRequestMuse', {'device': identifier});
    print('Disconnecting from device: $identifier');

    final device = deviceHandler; // Local variable to check if it has been assigned

    if (device != null) { // Check if deviceHandler has been assigned
      try {
        await muse.disconnect(device, (DeviceIdentifier deviceId) {
          streamsStarted = false;
          print("Disconnected from ${device.platformName}");
        });
        return true; // Successfully disconnected
      } catch (e) {
        print('Failed to disconnect device ${device.platformName}: ${e.toString()}');
        return false; // Failed to disconnect
      }
    } else {
      print('Device was never connected, so no need to disconnect.');
      return false; // No device to disconnect
    }
  }

  
  @override
  Future<bool> startRecording(String recordingIdentifier) async {
    FlutterUxcam.logEventWithProperties('startingRecordingMuse',
        {'device': identifier, 'recordingMuse': recordingIdentifier});
    print('Starting recording');

    final device = deviceHandler; // Local variable to check if it has been assigned

    if (device != null) { // Check if deviceHandler has been assigned
      try {
        // Start streaming
        if (!streamsStarted){
          await startStreaming(device);
          streamsStarted = true;
          dev.log("Stream started");
        }
        // Start session to make recording folder
        if (!sessionStarted){
          startSession(device, recordingIdentifier);
          sessionStarted = true;
          dev.log("Session started");
        } else {
          dev.log("Session was already started. TODO: handle these cases");
        }
        // Notify sensorInstance
        onRecordingStarted(recordingIdentifier);
        print('Started recording');
        return true;
      } catch (e) {
        print('Failed to start recording: ${e.toString()}');
        var errMessage = e.toString();
        if (e is PlatformException) {
          errMessage = "${e.message}, code: ${e.code}, details: ${e.details}";
          print("Error when trying to start recording. Error: $errMessage");
        }
        FlutterUxcam.logEventWithProperties('failedStartingRecordingMuse',
            {'device': identifier, 'error': errMessage});
        return false;
      }
    } else {
        print('Device was never connected, so no need to disconnect.');
        return false;
    }
  }

  void startSession(BluetoothDevice device, String recordingIdentifier) async {
    //sessionStarted[device.remoteId] = true; // Mark session as started for this device
    sessionStarted = true;
    fileHandler.createFolder(recordingIdentifier);
  }
  void stopSession(BluetoothDevice device) async {
    fileHandler.formattedRecId = '';
    //sessionStarted[device.remoteId] = false; // Mark session as ended for this device
    sessionStarted = false;
    
    // Add logic here for what happens when a session ends
  }
  
  Future <void> startStreaming(BluetoothDevice device) async {
    try {
      muse.startStreams(device, (DeviceIdentifier deviceId) {
      streamsStarted = true;
      //streamsStarted[device.remoteId] = true; // Update state when streams are started
      print("Started streaming from ${device.platformName}");
    });
  } catch (e) {
      // Handle disconnection error
      print("Failed to started streaming from ${device.platformName}");
    }
  }

  Future <void> stopStreaming(BluetoothDevice device) async {
    try {
      muse.stopStreams(device, (DeviceIdentifier deviceId) {
        streamsStarted = false;
      //streamsStarted[device.remoteId] = false; // Update state when streams are started
      print("Stopped streaming from ${device.platformName}");
    });
  } catch (e) {
    // Handle disconnection error
    print("Failed to stop streaming from ${device.platformName}");
    }
  }

  @override
  Future<bool> stopRecording() async {
    FlutterUxcam.logEventWithProperties(
        'stoppingRecordingMuse', {'device': identifier});
    dev.log('Stopping recording');
    // deviceHandler is initialized in init, once device is first connected
    final device = deviceHandler; // Local variable to check if it has been assigned

    if (device != null) { // Check if deviceHandler has been assigned
      // Fetch device from identifier and stop recording
      try {
        // Stop streaming 
        if (streamsStarted){
          await stopStreaming(device);
        } else {
          dev.log("Stream was already stopped (or at least the flag said so)");
        }
        // Start session to make recording folder
        if (sessionStarted){
          stopSession(device);
        } else {
          dev.log("Session was already stopped (or at least the flag said so). TODO: handle these cases");
        }
        onRecordingStopped();
        dev.log('Stopped recording');
        return true;
      } catch (e) {
        dev.log('Failed to stop recording: ${e.toString()}');
        var errMessage = e.toString();
        if (e is PlatformException) {
          errMessage = "${e.message}, code: ${e.code}, details: ${e.details}";
          dev.log("Error when trying to stop recording. Error: $errMessage");
        }
        FlutterUxcam.logEventWithProperties('failedStoppingRecordingMuse',
            {'device': identifier, 'error': errMessage});
        return false;
      }
    } else {
      print('Device was never connected, so no need to disconnect.');
      return false; // No device to disconnect
    }
  }

  @override
  Future<bool> isRecording() async {
    print('Getting recording status');
    if (streamsStarted && sessionStarted){
      return true;
    }
    else {
      return false;
    }
  }

  @override
  Future<List<String>> fetchData(String recordingIdentifier) async {
    // We ignore the recordingIdentifier for Muse, as it only supports one recording at a time
    print('Fetching recording for Muse (ignoring id $recordingIdentifier)');
    
    // Always make sure the recording has stopped before fetching
    if (await isRecording()){
      await stopRecording();
    }
    
    onFetchingDataStart();
    List<String> dataList = [];
    
    // First check status, to confirm there's even any recordings. Listing takes long and throws errors if there's no recordings
    try {
      for (var entry in dataTypeMappings.entries) { // Retrieving data from all sensors ['EEG', 'PPG', 'accel', 'gyro']
        String key = entry.key;
        dynamic value = entry.value;
        String? data = await fileHandler.getData(recordingIdentifier, key);
        if (data != null) {
          dev.log("Fetched $key data with: $value");
          dataList.add(data);
        } else {
          dev.log("Couldn't fetch the $key data");
        }
      }
      
      return dataList;
    } catch (e) {
      dev.log("Error fetching data: $e");
      rethrow;
    } finally {
      onFetchingDataEnd();
    }
  }

  @override
  Future<void> emptyRecordings(String recordingIdentifier) async {
    // Don't list recording before emptying because if its empty, it will take long and throw errors
    FlutterUxcam.logEventWithProperties(
        'emptyingRecordingsMuse', {'device': identifier});
    print('Emptying recordings');
    // Delete the file on the location
    try {
      await fileHandler.deleteFile(recordingIdentifier, dataTypeMappings.keys.toList());
      dev.log("Deleted local Muse data");
    } catch (e) {
      dev.log("Error deleting data: $e");
    }
  }

  @override
  Future<void> resetSensor() async {
    print('No Reset logic for the Muse device:  $identifier');
    //await muse.doFactoryReset(identifier, true /* preserve pairing info */);
  }

  @override
  StreamSubscription<List<ScanResult>> scanForSensor(Function onDeviceFound) {
    // Start scanning with keywords
    muse.startScan(timeout: const Duration(seconds: 9), withKeywords: [identifier]);

    // Listen to Scan Results
    return muse.scanResultsStream.listen((results) {
      for (var result in results) {
        if (result.device.platformName == identifier) {
          print("FOUND MUSE EVENT: ${result.device.platformName}, ${result.device.remoteId}");
          FlutterUxcam.logEventWithProperties(
            'foundMuse',
            {'device': result.device.platformName, 'remoteId': result.device.remoteId},
          );
          onDeviceFound(result.device);
        }
      }
    }, onError: (e) {
      FlutterUxcam.logEventWithProperties('scanErrorPolar', {'device': identifier});
      dev.log('MUSE Error during scan: $e');
    });
  }

  @override
  Future<bool> signalQuality() async {
    Map<int, bool> channelQualities = await signalQualityCheck();
    return channelQualities.values.every((isAcceptable) => isAcceptable);
  }

  @override
  Future<Map<int, bool>> signalQualityCheck() async {
    double THRESHOLD = 15;
    // Ensure that the stream is started
    final device = deviceHandler; // Local variable to check if it has been assigned
    if (device != null) { // Check if deviceHandler has been assigned
      if (!streamsStarted){
        await startStreaming(device);
        streamsStarted = true;
        dev.log("Stream started");
      }
    }

    Completer<Map<int, bool>> completer = Completer<Map<int, bool>>();
    Map<int, bool> result = {};
    muse.eegEpochNotifier.addListener(() {
      var eegdata = muse.eegEpochNotifier.value;
      if (eegdata != null) {
        for (int i = 0; i < eegdata.data.length; i++) {
          double standardDeviation = calculateStandardDeviation(eegdata.data[i]);
          result[i + 1] = standardDeviation < THRESHOLD;
        }
        completer.complete(result);
      }
    });
    return completer.future;
  }

  /// Helper function to calculate standard deviation of a data list.
  double calculateStandardDeviation(List<double> data) {
    if (data.isEmpty) return 0.0;

    // Filter out invalid values
    List<double> validData = data.where((value) => value.isFinite).toList();
    if (validData.isEmpty) return 0.0;

    double mean = validData.reduce((a, b) => a + b) / validData.length;
    double sumSquares = validData
        .map((val) => (val - mean) * (val - mean))
        .reduce((a, b) => a + b);

    return sqrt(sumSquares / validData.length);
  }
}


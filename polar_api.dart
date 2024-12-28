import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_uxcam/flutter_uxcam.dart';
import 'package:polar/polar.dart';
import 'package:uuid/uuid.dart';
import 'package:self_science_station/provider/sensor_provider.dart';
import 'package:self_science_station/model/sensor_model.dart';
import 'package:self_science_station/sensor/sensorInstance.dart';
import 'package:flutter/services.dart';

class PolarAPI extends SensorInstance {
  //Function _onSensorChange;
  final identifier;
  final polarName;
  final polar = Polar();
  final logs = ['Service started'];

  PolarExerciseEntry? exerciseEntry;
  //SensorProvider sp;
  // A constructor that calls the super constructor with the model instance and type parameters
  // -- this shouldn't be necessary when all child-instances are created by the super-class SensorProvider
  //PolarAPI(SensorInstanceModel sInstance, SensorTypeModel sType) : super(SensorInstanceModel sInstance, SensorTypeModel sType);

  PolarAPI(super.sp, super.sInstance, super.sType, this.identifier,
      this.polarName) {
    initState();
  }

  void initState() async {
    try {
      await polar.requestPermissions();
    } catch (e) {
      print('Failed to request permissions: ${e.toString()}');
      try {
        log('POLAR Error requesting Bluetooth Permissions: ${e.toString()}');
        FlutterUxcam.logEventWithProperties("errorRequestingPermissionsPolar", {
          "error": e.toString(),
          "device": identifier,
        });
      } catch (reportingErr) {
        log('POLAR Error reporting bug to Uxcam: ${reportingErr.toString()}');
      }
    }
    polar.batteryLevel.listen((PolarBatteryLevelEvent event) => () {
          if (event.identifier == identifier) {
            if (event.level < 30) {
              FlutterUxcam.logEventWithProperties('lowBatteryPolar',
                  {'level': event.level, 'device': identifier});
            }
            if (event.level < 5) {
              sState.availabilityState = SensorAvailabilityState.faulty;
            }
          }
        });
    polar.deviceConnecting.listen((PolarDeviceInfo polarDeviceInfo) {
      if (polarDeviceInfo.deviceId == identifier) {
        log("CONNECTING POLAR EVENT");
        FlutterUxcam.logEventWithProperties(
            'connectingPolar', {'device': identifier});
        onConnecting();
      }
    });
    polar.deviceConnected.listen((PolarDeviceInfo polarDeviceInfo) {
      if (polarDeviceInfo.deviceId == identifier) {
        log("CONNECTED POLAR EVENT");

        FlutterUxcam.logEventWithProperties(
            'connectedPolar', {'device': identifier});
        onConnected();
      }
    });
    polar.deviceDisconnected.listen((PolarDeviceDisconnectedEvent event) {
      if (event.info.deviceId == identifier) {
        log("DISCONNECTED POLAR EVENT");

        FlutterUxcam.logEventWithProperties(
            'disconnectedPolar', {'device': identifier});

        // For Polar, if it disconnects, it means it is not being worn, so it is available
        sState.availabilityState = SensorAvailabilityState.available;
        onDisconnected();
      }
    });
    polar.disInformation.listen((PolarDisInformationEvent event) {
      if (event.identifier == identifier) {
        log("DIS INFO POLAR EVENT: ${event.uuid}, ${event.info}");
        FlutterUxcam.logEventWithProperties('disInfoPolar',
            {'device': identifier, 'uuid': event.uuid, 'info': event.info});
      }
    });
    polar.sdkFeatureReady.listen((PolarSdkFeatureReadyEvent polarSdkReady) {
      if (polarSdkReady.identifier == identifier) {
        var featureJson = polarSdkReady.feature.toJson();
        var featureStr = jsonEncode(featureJson);
        log("SDK READY POLAR EVENT: $featureStr");

        FlutterUxcam.logEventWithProperties(
            'sdkReadyPolar', {'device': identifier, 'feature': featureStr});
      }
    });
  }

  @override
  Future<bool> connectSensor() async {
    // onConnecting();
    log('POLAR Connecting to device: $identifier');
    FlutterUxcam.logEventWithProperties(
        'connectRequestPolar', {'device': identifier});
    try {
      await polar.connectToDevice(identifier);
    } catch (e) {
      log('POLAR Failed to connect device $identifier: ${e.toString()}');
      return false;
    }
    return true;
  }

  @override
  void connectSensorWithTimeout(
      {required timeout, Function? connectionCallback}) async {
    FlutterUxcam.logEventWithProperties(
        'connectWithTimeoutRequestPolar', {'device': identifier});
    print("Connecting sensor $identifier with timeout $timeout");
    // onConnecting();
    await polar.connectToDevice(identifier);
    print("Called connectToDevice");
    Future.delayed(timeout, () {
      if (sState.connectionState != SensorConnectionState.connected) {
        print("Connection timeout reached. Bailing.");
        FlutterUxcam.logEventWithProperties(
            'connectionTimedOutPolar', {'device': identifier});
      }
      if (connectionCallback != null) {
        connectionCallback(
            sState.connectionState == SensorConnectionState.connected);
      }
    });
  }

  @override
  Future<bool> disconnectSensor() async {
    FlutterUxcam.logEventWithProperties(
        'disconnectRequestPolar', {'device': identifier});
    log('POLAR  Disconnecting from device: $identifier');
    try {
      await polar.disconnectFromDevice(identifier);
    } catch (e) {
      log('POLAR  Failed to disconnect device $identifier: ${e.toString()}');
      return false;
    }
    return true;
  }

  @override
  Future<bool> startRecording(String recordingIdentifier) async {
    FlutterUxcam.logEventWithProperties('startingRecordingPolar',
        {'device': identifier, 'recordingPolar': recordingIdentifier});
    log('POLAR Starting recording');
    
    // Prepare device for recording: stop rec and empty device if applicable
    await prepareDeviceforRecording();

    try {
      await polar.startRecording(
        identifier,
        exerciseId: recordingIdentifier, //?? const Uuid().v4(),
        interval: RecordingInterval.interval_1s,
        sampleType: SampleType.rr,
      );
      onRecordingStarted(recordingIdentifier);
      log('POLAR Started recording');
    } catch (e) {
      log('POLAR Failed to start recording: ${e.toString()}');
      var errMessage = e.toString();
      if (e is PlatformException) {
        errMessage = "${e.message}, code: ${e.code}, details: ${e.details}";
        log("Error when trying to start recording. Error: $errMessage");
      }
      FlutterUxcam.logEventWithProperties('failedStartingRecordingPolar',
          {'device': identifier, 'error': errMessage});
      return false;
    }
    return true;
  }

  @override
  Future<bool> stopRecording() async {
    FlutterUxcam.logEventWithProperties(
        'stoppingRecordingPolar', {'device': identifier});
    log('POLAR  Stopping recording');
    try {
      await polar.stopRecording(identifier);
      onRecordingStopped();
      log('POLAR  Stopped recording');
    } catch (e) {
      log('POLAR  Failed to stop recording: ${e.toString()}');
      var errMessage = e.toString();
      if (e is PlatformException) {
        errMessage = "${e.message}, code: ${e.code}, details: ${e.details}";
        log("Error when trying to stop recording. Error: $errMessage");
      }
      FlutterUxcam.logEventWithProperties('failedStoppingRecordingPolar',
          {'device': identifier, 'error': errMessage});
      return false;
    }
    return true;
  }

  @override
  Future<bool> isRecording() async {
    log('POLAR Getting recording status');
    try {
      final status = await polar.requestRecordingStatus(identifier);
      log('POLAR  Recording status: $status');
      return status.ongoing;
    } catch (e) {
      if (e is PlatformException) {
        FlutterUxcam.logEventWithProperties('failedStoppingRecordingPolar',
          {'device': identifier, 'error': e.message, 'code': e.code, 'details': e.details});
        print(
            "Error when trying to get recording status. isRecording set to false. Error: ${e.message}, code: ${e.code}, details: ${e.details}");
        return false;
      }
    }
    return false;
  }

  @override
  Future<List<int>> fetchData(String recordingIdentifier) async {
    // We ignore the recordingIdentifier for Polar, as it only supports one recording at a time
    print('Fetching recording for polar (ignoring id $recordingIdentifier)');
    print('This is the ID used $identifier');
    try {
      // First check status, to confirm there's even any recordings. Listing takes long and throws errors if there's no recordings
      final status = await polar.requestRecordingStatus(identifier);
      if (status.ongoing){
        // Always make sure the recording has stopped before fetching
        log("POLAR Stopping the recording to fetch data");
        await stopRecording();
        log("POLAR Stopped the recording before fetching data");
      }
      if (status.entryId != ""){
        onFetchingDataStart();
        final entries = await polar.listExercises(identifier);
        for (var entry in entries) {
          final data = await polar.fetchExercise(identifier, entry);
          print('Fetched recording: $data');
          // Moved the removal of data to empty recordings
          return data.samples;
        }
      }
      else {
        log("No recording to fetch");
      }
    } catch (e) {
      rethrow;
    } finally {
      onFetchingDataEnd();
    }
    return [];
  }

    Future<void> prepareDeviceforRecording() async {
    print('Preparing device for recording');
    // Don't list recording before emptying because if its empty, it will take long and throw errors
    FlutterUxcam.logEventWithProperties(
        'preparingPolarForRec', {'device': identifier});
    // First check status, to see if its recording and stop it if it is
    final status = await polar.requestRecordingStatus(identifier);
    log("POLAR status: $status");
    if (status.ongoing){
      // Always make sure the recording has stopped before fetching
      log("POLAR Stopping the recording to fetch data");
      await stopRecording();
      log("POLAR Stopped the recording before fetching data");
    }
    // Check if there's even any recordings. Listing takes long and throws errors if there's no recordings
    if (status.entryId != ""){
      final entries = await polar.listExercises(identifier);
      print(entries);
      for (var entry in entries) {
        await polar.removeExercise(identifier, entry);
      }
      log("POLAR removed recordings");
    }
    else {
      log("POLAR No recording to remove");
      }
  }

  @override
  Future<void> emptyRecordings(String recordingIdentifier) async {
    // TODO: Eventually add logic to delete just a particular entry/exercise (recordingIdentifier)
    // Don't list recording before emptying because if its empty, it will take long and throw errors
    FlutterUxcam.logEventWithProperties(
        'emptyingRecordingsPolar', {'device': identifier});
    print('Emptying recordings');
    // First check status, to confirm there's even any recordings. Listing takes long and throws errors if there's no recordings
    final status = await polar.requestRecordingStatus(identifier);
    print(status);
    if (status.entryId != ""){
      final entries = await polar.listExercises(identifier);
      print(entries);
      for (var entry in entries) {
        await polar.removeExercise(identifier, entry);
      }
      log("POLAR removed recordings");
    }
    else {
      log("POLAR No recording to remove");
      }
  }

  @override
  Future<void> resetSensor() async {
    print('Resetting sensor $identifier');
    await polar.doFactoryReset(identifier, true /* preserve pairing info */);
  }

  @override
  StreamSubscription<PolarDeviceInfo> scanForSensor(Function onDeviceFound) {
    return polar.searchForDevice().listen((e) {
      FlutterUxcam.logEventWithProperties(
          'deviceFoundPolar', {'device': e.deviceId});
      log('POLAR Device found from scan: ${e.deviceId}, isConnectable: ${e.isConnectable}');
      // if (e.isConnectable) {
      onDeviceFound(e.deviceId);
      // }
    }, onError: (e) {
      FlutterUxcam.logEventWithProperties(
          'scanErrorPolar', {'device': identifier});
      log('POLAR Error during scan: $e');
    }, onDone: () {
      log('POLAR Scan done!');
    });
  }

  // For Online Streaming. Polar has an offline API but it doesn't seem available through this flutter wrapper
  void streamWhenReady() async {
    await polar.sdkFeatureReady.firstWhere(
      (e) =>
          e.identifier == identifier &&
          e.feature ==
              PolarSdkFeature
                  .onlineStreaming, // Online, but it continues offline if disconnected by itself
    );
    final availabletypes =
        await polar.getAvailableOnlineStreamDataTypes(identifier);

    debugPrint('available types: $availabletypes');

    if (availabletypes.contains(PolarDataType.hr)) {
      polar
          .startHrStreaming(identifier)
          .listen((e) => log('POLAR Heart rate: ${e.samples.map((e) => e.hr)}'));
    }
    if (availabletypes.contains(PolarDataType.ecg)) {
      polar
          .startEcgStreaming(identifier)
          .listen((e) => log('POLAR ECG data received'));
    }
    if (availabletypes.contains(PolarDataType.acc)) {
      polar
          .startAccStreaming(identifier)
          .listen((e) => log('POLAR ACC data received'));
    }
  }

  void log(String log) {
    // ignore: avoid_print
    print(log);
  }

  Future<void> _handleRecordingAction(RecordingAction action) async {
    switch (action) {
      case RecordingAction.start:
        log('POLAR Starting recording');
        final recordingID = const Uuid().v4();
        await polar.startRecording(
          identifier,
          exerciseId: recordingID,
          interval: RecordingInterval.interval_1s,
          sampleType: SampleType.rr,
        );
        onRecordingStarted(recordingID);
        log('POLAR  Started recording');
        break;
      case RecordingAction.stop:
        log('POLAR  Stopping recording');
        await polar.stopRecording(identifier);
        onRecordingStopped();
        log('POLAR  Stopped recording');
        break;
      case RecordingAction.status:
        log('POLAR  Getting recording status');
        final status = await polar.requestRecordingStatus(identifier);
        log('POLAR  Recording status: $status');
        // TODO update the sensor state depending on the status
        break;
      case RecordingAction.list:
        log('POLAR  Listing recordings');
        final entries = await polar.listExercises(identifier);
        log('POLAR Recordings: $entries');
        // H10 can only store one recording at a time
        exerciseEntry = entries.first;
        break;
      case RecordingAction.fetch:
        log('POLAR  Fetching recording');
        if (exerciseEntry == null) {
          log('POLAR Exercises not yet listed');
          await _handleRecordingAction(RecordingAction.list);
        }
        final entry = await polar.fetchExercise(identifier, exerciseEntry!);
        log('POLAR Fetched recording: $entry');
        break;
      case RecordingAction.remove:
        log('POLAR Removing recording');
        if (exerciseEntry == null) {
          log('POLAR No exercise to remove. Try calling list first.');
          return;
        }
        await polar.removeExercise(identifier, exerciseEntry!);
        log('POLAR Removed recording');
        break;
    }
  }
}

enum RecordingAction {
  start,
  stop,
  status,
  list,
  fetch,
  remove,
}

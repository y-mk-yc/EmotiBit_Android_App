import 'dart:developer' as dev;
import 'dart:async';
import 'dart:io';
import 'package:meta/meta.dart';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:self_science_station/sensor/muse_sdk.dart';
import 'package:self_science_station/utils/constants.dart';

import 'package:flutter/material.dart';
import 'package:self_science_station/model/metric_model.dart';
import 'package:self_science_station/model/sensor_model.dart';
import 'package:self_science_station/utils/utils.dart';
import 'package:self_science_station/sensor/polar_api.dart';
import 'package:self_science_station/provider/sensor_provider.dart';
import 'package:provider/provider.dart';

import 'package:polar/polar.dart';
import 'package:tuple/tuple.dart';

// Structs
enum SensorConnectionState { connected, connecting, disconnected, init }

enum SensorAvailabilityState {
  available, // ready for use
  unavailable, // in use
  faulty, // cannot be used and requires some type of maintenance
  init
}

enum SensorAcquisitionState { idle, acquiring, fetching, init }

class SensorState {
  SensorConnectionState connectionState;
  SensorAvailabilityState availabilityState;
  SensorAcquisitionState acquisitionState;

  SensorState({
    required this.connectionState,
    required this.availabilityState,
    required this.acquisitionState,
  });

  // Copy constructor
  SensorState.copy(SensorState sensorState)
      : connectionState = sensorState.connectionState,
        availabilityState = sensorState.availabilityState,
        acquisitionState = sensorState.acquisitionState;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is SensorState &&
        other.connectionState == connectionState &&
        other.availabilityState == availabilityState &&
        other.acquisitionState == acquisitionState;
  }

  @override
  int get hashCode =>
      connectionState.hashCode ^
      availabilityState.hashCode ^
      acquisitionState.hashCode;
}

// SensorInstance is the class for all sensor instances and parent-class for all mobile SDKs/APIs

class SensorInstance {
  // Getters for the state variables
  get isConnected => sState.connectionState == SensorConnectionState.connected;
  get isConnecting =>
      sState.connectionState == SensorConnectionState.connecting;
  get isDisconnected =>
      sState.connectionState == SensorConnectionState.disconnected;
  get isAvailable =>
      sState.availabilityState == SensorAvailabilityState.available;
  get isRec => sState.acquisitionState == SensorAcquisitionState.acquiring;

  // TODO merge this (along with the other state variables) into a single state variable
  bool isFetching = false;
  // Whether the sensor has data we need to fetch
  bool requiresFetching = false;

  // When each recording started
  final Map<String, String> _recordingTimestamps = {};

  // InstanceModel and TypeModel are final because their values should not be change once the instance is created
  final SensorProvider sp;
  final SensorInstanceModel _sInstance;
  final SensorTypeModel _sType;

  // Allows for executing callbacks for a given sensor state transition
  final Map<Tuple2<SensorState, SensorState>, Function> _transitionTable = {};

  void addTransition(
      SensorState fromState, SensorState toState, Function callback) {
    _transitionTable[Tuple2(fromState, toState)] = callback;
  }

  void executeTransition(SensorState fromState, SensorState toState) {
    var transition = _transitionTable[Tuple2(fromState, toState)];
    if (transition != null) {
      transition();
    }
  }

  // SensorState and Availability will describe the accessibility of the sensor
  SensorState sState = SensorState(
      connectionState: SensorConnectionState.init,
      availabilityState: SensorAvailabilityState.init,
      acquisitionState: SensorAcquisitionState.init);

  // Constructor (without subclass-instance creation)
  SensorInstance(this.sp, this._sInstance, this._sType) {
    print("New Sensor created in SensorProvider without any subclass assigned");
    print(
        "New sensor instance instance created: name ${_sType.vendor} ${_sType.name}: ${_sInstance.deviceID}");
    sp.updateEverything();
  }

  // Factory constructor creating a subclass instance for the particular sensor
  factory SensorInstance.create(SensorProvider sProvider,
      SensorInstanceModel sInstance, SensorTypeModel sType) {
    String sVendor = sType.vendor;
    String sDeviceName = sType.name;
    String sDeviceID = sInstance.deviceID;

    // Create and return a child-instance for the particular sensor based on Vendor
    SensorInstance sDevice;
    switch (sVendor) {
      case "fitbit":
        // TODO:
        dev.log("Fitbit Sensor");
        dev.log("Fitbit is webbased");
        sDevice = SensorInstance(sProvider, sInstance, sType);
        break;

      case "withings":
        // TODO:
        dev.log("Withings Sensor");
        dev.log("Withings is webbased");
        sDevice = SensorInstance(sProvider, sInstance, sType);
        break;

      case "polar":
        dev.log("Polar Sensor");
        sDevice = PolarAPI(sProvider, sInstance, sType, sDeviceID, sDeviceName);
        break;

      case "muse":
        dev.log("Muse Sensor");
        sDevice = MuseSDK(sProvider, sInstance, sType, sDeviceID, sDeviceName);
        break;

      default:
        // TODO:
        dev.log("This sensor has not been initialized correctly.");
        sDevice = SensorInstance(sProvider, sInstance, sType);
        break;
    }

    return sDevice;
  }

  Future<bool> startRecording(String recordingIdentifier) {
    dev.log(
        "SENSOR Recording from sensor ${_sInstance.id} with ID $recordingIdentifier");
    onRecordingStarted(recordingIdentifier);
    return Future.value(true);
  }

  Future<bool> stopRecording() {
    dev.log("SENSOR Stopping recording from sensor ${_sInstance.id}");
    onRecordingStopped();
    return Future.value(true);
  }

  Future<void> emptyRecordings(String recordingIdentifier) async {
    print('SENSOR Emptying recordings for sensor ${_sInstance.id}');
    return Future.value();
  }

  Future<bool> isRecording() {
    dev.log("SENSOR Checking if recording from sensor ${_sInstance.id}");
    return Future.value(false);
  }

  Future<bool> connectSensor() async {
    print("SENSOR Connecting sensor ${_sInstance.id}");
    onConnected();
    return Future.value(true);
  }

  // Tries to connect, waits for specified timeout, bails if hasn't connected yet
  void connectSensorWithTimeout(
      {required timeout, Function? connectionCallback}) async {
    dev.log("SENSOR Connecting sensor ${_sInstance.id} with timeout $timeout");
    onConnecting();
    Future.delayed(timeout, () {
      if (sState.connectionState != SensorConnectionState.connected) {
        onConnectFail();
      } else {
        onConnected();
      }
      if (connectionCallback != null) {
        connectionCallback(
            sState.connectionState == SensorConnectionState.connected);
      }
    });
  }

  Future<bool> disconnectSensor() {
    print("SENSOR Disconnecting sensor ${_sInstance.id}");
    onDisconnected();
    return Future.value(true);
  }

  void markUnavailable() {
    print("SENSOR Marking sensor ${_sInstance.id} as unavailable");
    final prevState = SensorState.copy(sState);
    sState.availabilityState = SensorAvailabilityState.unavailable;
    handleStateChange(prevState, sState);
  }

  Future<void> resetSensor() {
    print("SENSOR Resetting sensor ${_sInstance.id}");
    return Future.value();
  }

  StreamSubscription<dynamic> scanForSensor(Function onDeviceFound) {
    print("SENSOR Scanning for sensor ${_sInstance.id}");
    onDeviceFound(_sInstance.deviceID);
    return const Stream.empty().listen((event) {});
  }

  @protected
  void onRecordingStarted(String? recordingIdentifier) {
    print("SENSOR Started recording from sensor ${_sInstance.id} with ID: $recordingIdentifier");
    if (recordingIdentifier != null) {
      _recordingTimestamps[recordingIdentifier] = DateTime.now().toString();
    }

    final prevState = SensorState.copy(sState);
    sState.acquisitionState = SensorAcquisitionState.acquiring;
    handleStateChange(prevState, sState);
  }

  @protected
  void onRecordingStopped() {
    print("SENSOR Stopped recording from sensor ${_sInstance.id}");
    final prevState = SensorState.copy(sState);
    sState.acquisitionState = SensorAcquisitionState.idle;
    handleStateChange(prevState, sState);
  }

  @protected
  void onFetchingDataStart() {
    print("SENSOR Fetching data from sensor ${_sInstance.id}");
    isFetching = true;
    final prevState = SensorState.copy(sState);
    sState.acquisitionState = SensorAcquisitionState.fetching;
    handleStateChange(prevState, sState);
  }

  @protected
  onFetchingDataEnd() {
    print("SENSOR Fetched data from sensor ${_sInstance.id}");
    requiresFetching = false;
    isFetching = false;
    final prevState = SensorState.copy(sState);
    sState.acquisitionState = SensorAcquisitionState.idle;
    handleStateChange(prevState, sState);
  }

  @protected
  void onConnecting() {
    print("SENSOR Connecting sensor ${_sInstance.id}");
    final prevState = SensorState.copy(sState);
    sState.connectionState = SensorConnectionState.connecting;
    handleStateChange(prevState, sState);
  }

  @protected
  void onConnected() {
    print("SENSOR Connected sensor ${_sInstance.id}");
    final prevState = SensorState.copy(sState);
    sState.connectionState = SensorConnectionState.connected;
    handleStateChange(prevState, sState);
  }

  @protected
  void onDisconnected() {
    print("SENSOR Disconnected sensor ${_sInstance.id}");
    final prevState = SensorState.copy(sState);
    sState.connectionState = SensorConnectionState.disconnected;
    handleStateChange(prevState, sState);
  }

  @protected
  void onConnectFail() {
    print("SENSOR Failed to connect to sensor ${_sInstance.id}");
    onDisconnected();
  }

  @protected
  void onSensorError() {
    print("SENSOR Error on sensor ${_sInstance.id}!");
    final prevState = SensorState.copy(sState);
    sState.availabilityState = SensorAvailabilityState.faulty;
    handleStateChange(prevState, sState);
  }

  void handleStateChange(SensorState prevState, SensorState newState) {
    executeTransition(prevState, newState);
    // sp.syncSensorState(this);
    sp.updateEverything();
  }

  Future<dynamic> fetchData(String recordingIdentifier) {
    dev.log(
        'SENSOR Fetching from sensor ${_sInstance.id} for recording $recordingIdentifier');
    return Future.value([]);
  }

  String? getRecordingTimestamp(String? recordingIdentifier) {
    if (recordingIdentifier == null) {
      return null;
    }
    return _recordingTimestamps[recordingIdentifier];
  }

  SensorInstanceModel getSensorInstance() {
    return _sInstance;
  }

  SensorTypeModel getTypeModel() {
    return _sType;
  }

  Future<SensorAvailabilityState> checkSensorAvailability() {
    dev.log("SENSOR Checking sensor availability for ${_sInstance.id}");
    return Future.value(sState.availabilityState);
  }

  /// Checks if the overall signal quality is acceptable.
  Future<bool> signalQuality() async {
    Map<int, bool> channelQualities = await signalQualityCheck();
    return channelQualities.values.every((isAcceptable) => isAcceptable);
  }

  /// Checks the signal quality for each channel. To be overridden by child instances.
  Future<Map<int, bool>> signalQualityCheck() async {
    // Placeholder for child-specific implementation
    return Future.value({});
  }

}

import 'package:flutter/foundation.dart';

import 'plant_classifier.dart';
import 'plantgo_api.dart';
import 'species_catalog.dart';

/// The single entry point the UI uses to identify a plant.
///
/// Policy, in one place so the scanner screen does not have to reason about it:
///
/// * **Live camera frames** always use the on-device model. Round-tripping video
///   to a server is slow, costs money and needs a signal we may not have in the
///   field.
/// * **A still photo** uses on-device first, then asks the cloud model for a
///   second opinion when the local answer is shaky ([_needsSecondOpinion]) — or
///   when the caller explicitly wants the best possible answer.
/// * If the on-device model is missing, the cloud carries the whole load; if the
///   cloud is unreachable, on-device carries it. The app stays usable either way.
class IdentificationService {
  IdentificationService({
    PlantClassifier? classifier,
    PlantGoApi? api,
  })  : _classifier = classifier,
        _api = api;

  final PlantClassifier? _classifier;
  PlantGoApi? _api;

  String? _localUnavailableReason;
  bool? _cloudReachable;

  bool get hasLocalModel => _classifier != null;
  bool get hasCloud => _api != null;
  String? get localUnavailableReason => _localUnavailableReason;

  /// Loads whatever is available. Never throws: a failure to load the on-device
  /// model degrades the app, it should not stop it starting.
  static Future<IdentificationService> create({
    String? apiBaseUrl,
    String? apiToken,
  }) async {
    await SpeciesCatalog.load();

    PlantClassifier? classifier;
    String? reason;
    try {
      classifier = await PlantClassifier.load();
      debugPrint('[plantgo] on-device model ready (${classifier.numClasses} classes)');
    } on Object catch (e) {
      reason = e.toString();
      debugPrint('[plantgo] on-device model unavailable: $e');
    }

    final api = (apiBaseUrl != null && apiBaseUrl.isNotEmpty)
        ? PlantGoApi(baseUrl: apiBaseUrl, token: apiToken)
        : null;

    final service = IdentificationService(classifier: classifier, api: api)
      .._localUnavailableReason = reason;
    return service;
  }

  /// Fast path for live camera frames. Returns null when no local model is
  /// loaded — callers should not fall back to the network per frame.
  Future<IdentificationResult?> identifyFrame(Float32List input) async {
    final local = _classifier;
    if (local == null) return null;
    try {
      return await local.identifyFloats(input, topK: 3);
    } on Object catch (e) {
      debugPrint('[plantgo] frame inference failed: $e');
      return null;
    }
  }

  /// Best-effort identification of a captured photo.
  ///
  /// [preferCloud] forces the cloud attempt even when the local answer looks
  /// confident — used by the "get a better answer" button on the result card.
  Future<IdentificationResult> identifyPhoto(
    Uint8List bytes, {
    bool preferCloud = false,
  }) async {
    IdentificationResult? local;
    Object? localError;

    final classifier = _classifier;
    if (classifier != null) {
      try {
        local = await classifier.identifyBytes(bytes);
      } on Object catch (e) {
        localError = e;
        debugPrint('[plantgo] local identification failed: $e');
      }
    }

    final wantCloud = _api != null &&
        (preferCloud || local == null || _needsSecondOpinion(local));

    if (wantCloud) {
      try {
        final cloud = await _api!.identify(bytes);
        _cloudReachable = true;
        // Trust the cloud model unless it is clearly less sure than local.
        if (local == null ||
            (cloud.top?.confidence ?? 0) >= (local.top?.confidence ?? 0)) {
          return cloud;
        }
        return local;
      } on PlantGoApiException catch (e) {
        _cloudReachable = false;
        debugPrint('[plantgo] cloud identification failed: $e');
        if (local == null) {
          throw IdentificationUnavailable(
            'No model could identify this photo. '
            'On-device: ${localError ?? _localUnavailableReason ?? 'unavailable'}. '
            'Cloud: $e',
          );
        }
      }
    }

    if (local != null) return local;
    throw IdentificationUnavailable(
      'No identification model is available. '
      '${_localUnavailableReason ?? localError ?? ''}',
    );
  }

  /// A local answer is worth double-checking when it is weak, or when the top
  /// two guesses are close enough that the ranking is basically a coin flip.
  bool _needsSecondOpinion(IdentificationResult r) {
    final top = r.top;
    if (top == null) return true;
    if (top.confidence < IdentificationResult.confidentThreshold) return true;
    if (r.predictions.length >= 2) {
      final margin = top.confidence - r.predictions[1].confidence;
      if (margin < 0.15) return true;
    }
    return false;
  }

  /// Ask the server for a riddle. Returns null when unavailable, so the caller
  /// can fall back to a stored riddle rather than showing an error.
  Future<RiddleResult?> riddleFor(Species species) async {
    final api = _api;
    if (api == null) return null;
    try {
      final result = await api.generateRiddle(
        scientificName: species.scientificName,
      );
      if (!result.valid) {
        debugPrint('[plantgo] riddle came back malformed for '
            '${species.scientificName}; falling back');
        return null;
      }
      _cloudReachable = true;
      return result;
    } on PlantGoApiException catch (e) {
      _cloudReachable = false;
      debugPrint('[plantgo] riddle generation failed: $e');
      return null;
    }
  }

  Future<bool> checkCloud() async {
    final api = _api;
    if (api == null) return false;
    return _cloudReachable = await api.isReachable();
  }

  bool? get lastKnownCloudState => _cloudReachable;

  /// Swap the API endpoint at runtime (the existing IP settings screen).
  void updateEndpoint({required String baseUrl, String? token}) {
    _api?.close();
    _api = baseUrl.isEmpty ? null : PlantGoApi(baseUrl: baseUrl, token: token);
    _cloudReachable = null;
  }

  void dispose() {
    _classifier?.close();
    _api?.close();
  }
}

class IdentificationUnavailable implements Exception {
  const IdentificationUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

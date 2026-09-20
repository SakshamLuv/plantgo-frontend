import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'species_catalog.dart';

/// A ranked guess from either the on-device or the cloud model.
class PlantPrediction {
  const PlantPrediction({required this.species, required this.confidence});

  final Species species;
  final double confidence;

  String get label => species.commonName.isNotEmpty
      ? species.commonName
      : species.scientificName;

  @override
  String toString() =>
      '${species.scientificName} ${(confidence * 100).toStringAsFixed(1)}%';
}

/// Result of one identification attempt.
class IdentificationResult {
  const IdentificationResult({
    required this.predictions,
    required this.source,
    required this.inferenceMs,
  });

  final List<PlantPrediction> predictions;

  /// `onDevice` or `cloud` — surfaced in the UI so testers know which ran.
  final String source;
  final int inferenceMs;

  PlantPrediction? get top => predictions.isEmpty ? null : predictions.first;

  /// Below this the app asks the user to get closer rather than guessing.
  static const double confidentThreshold = 0.60;

  /// Between [uncertainThreshold] and [confidentThreshold] we show the guess but
  /// offer the cloud model for a second opinion.
  static const double uncertainThreshold = 0.35;

  bool get isConfident => (top?.confidence ?? 0) >= confidentThreshold;
  bool get isUsable => (top?.confidence ?? 0) >= uncertainThreshold;
}

/// On-device plant identification via TFLite.
///
/// The exported model has preprocessing baked in and expects raw `[0,255]`
/// float RGB at [SpeciesCatalog.inputSize]. Nothing here rescales — doing so
/// would double-apply normalisation and quietly wreck accuracy.
class PlantClassifier {
  PlantClassifier._(this._interpreter, this._catalog, this._inputSize);

  final Interpreter _interpreter;
  final SpeciesCatalog _catalog;
  final int _inputSize;

  static const String modelAsset = 'assets/models/plant_model.tflite';

  bool _closed = false;

  /// Serialises access: a TFLite [Interpreter] is not safe to call concurrently,
  /// and live camera frames will happily try.
  Future<void> _inFlight = Future.value();

  static Future<PlantClassifier> load({String asset = modelAsset}) async {
    final catalog = await SpeciesCatalog.load();

    final options = InterpreterOptions()..threads = 2;
    // XNNPACK on Android / Metal on iOS give a solid speedup, but both are
    // optional — a plain CPU interpreter is still fast enough for still photos.
    try {
      final interpreter = await Interpreter.fromAsset(asset, options: options);
      return PlantClassifier._(interpreter, catalog, catalog.inputSize)
        .._validateShapes();
    } on Object catch (e) {
      throw PlantClassifierUnavailable(
        'could not load $asset — has the trained model been copied in? ($e)',
      );
    }
  }

  void _validateShapes() {
    final inShape = _interpreter.getInputTensor(0).shape;
    final outShape = _interpreter.getOutputTensor(0).shape;

    if (inShape.length != 4 || inShape[1] != _inputSize || inShape[2] != _inputSize) {
      throw PlantClassifierUnavailable(
        'model expects input $inShape but labels.json says ${_inputSize}px',
      );
    }
    final classes = outShape.last;
    if (classes != _catalog.count) {
      throw PlantClassifierUnavailable(
        'model outputs $classes classes but labels.json has ${_catalog.count}; '
        'the model and label file are from different training runs',
      );
    }
  }

  int get numClasses => _catalog.count;

  /// Identify from already-decoded image bytes (JPEG/PNG).
  Future<IdentificationResult> identifyBytes(Uint8List bytes, {int topK = 5}) {
    return _enqueue(() async {
      final decoded = await compute(_decodeAndResize,
          _ResizeRequest(bytes: bytes, size: _inputSize));
      if (decoded == null) {
        throw const FormatException('could not decode image');
      }
      return _run(decoded, topK);
    });
  }

  /// Identify from an already-prepared `[size*size*3]` float buffer in `[0,255]`.
  Future<IdentificationResult> identifyFloats(Float32List input, {int topK = 5}) {
    final expected = _inputSize * _inputSize * 3;
    if (input.length != expected) {
      throw ArgumentError('expected $expected floats, got ${input.length}');
    }
    return _enqueue(() async => _run(input, topK));
  }

  /// Runs [task] after any in-flight inference finishes.
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _inFlight = _inFlight.then((_) async {
      if (_closed) {
        completer.completeError(StateError('classifier already closed'));
        return;
      }
      try {
        completer.complete(await task());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  IdentificationResult _run(Float32List input, int topK) {
    final sw = Stopwatch()..start();

    final inputTensor = input.reshape([1, _inputSize, _inputSize, 3]);
    final output = List.filled(_catalog.count, 0.0).reshape([1, _catalog.count]);
    _interpreter.run(inputTensor, output);
    final scores = (output[0] as List).cast<double>();

    sw.stop();
    return IdentificationResult(
      predictions: _rank(scores, topK),
      source: 'onDevice',
      inferenceMs: sw.elapsedMilliseconds,
    );
  }

  List<PlantPrediction> _rank(List<double> scores, int topK) {
    // The exported model ends in softmax, but a quantised graph can drift a
    // little; renormalise so the confidences the UI shows always sum to 1.
    final sum = scores.fold<double>(0, (a, b) => a + b);
    final probs = sum > 0.001
        ? scores.map((s) => s / sum).toList()
        : _softmax(scores);

    final order = List<int>.generate(probs.length, (i) => i)
      ..sort((a, b) => probs[b].compareTo(probs[a]));

    return order
        .take(math.min(topK, probs.length))
        .map((i) => PlantPrediction(
              species: _catalog.byIndex(i),
              confidence: probs[i].clamp(0.0, 1.0),
            ))
        .toList();
  }

  static List<double> _softmax(List<double> xs) {
    final max = xs.reduce(math.max);
    final exps = xs.map((x) => math.exp(x - max)).toList();
    final total = exps.fold<double>(0, (a, b) => a + b);
    return exps.map((e) => e / total).toList();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _interpreter.close();
  }
}

class PlantClassifierUnavailable implements Exception {
  const PlantClassifierUnavailable(this.message);
  final String message;
  @override
  String toString() => 'PlantClassifierUnavailable: $message';
}

// --------------------------------------------------------------------------
// Decoding runs in an isolate: a 12MP JPEG takes long enough to drop frames.
// --------------------------------------------------------------------------

class _ResizeRequest {
  const _ResizeRequest({required this.bytes, required this.size});
  final Uint8List bytes;
  final int size;
}

Float32List? _decodeAndResize(_ResizeRequest req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return null;

  // Centre-crop to square first, so a wide photo is not squashed — the model
  // was trained on square resizes of roughly centred subjects.
  final side = math.min(decoded.width, decoded.height);
  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized =
      img.copyResize(cropped, width: req.size, height: req.size, interpolation: img.Interpolation.linear);

  final out = Float32List(req.size * req.size * 3);
  var i = 0;
  for (var y = 0; y < req.size; y++) {
    for (var x = 0; x < req.size; x++) {
      final p = resized.getPixel(x, y);
      out[i++] = p.r.toDouble(); // [0,255] — the model preprocesses internally
      out[i++] = p.g.toDouble();
      out[i++] = p.b.toDouble();
    }
  }
  return out;
}

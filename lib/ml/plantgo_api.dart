import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'plant_classifier.dart';
import 'species_catalog.dart';

/// Client for the PlantGo inference API (the cloud half of identification and
/// the riddle generator).
///
/// Nothing here is required for the app to function: if the API is unreachable
/// the caller falls back to the on-device model and to stored riddles. Every
/// method therefore throws a typed [PlantGoApiException] rather than leaking
/// Dio errors into the UI layer.
class PlantGoApi {
  PlantGoApi({required String baseUrl, String? token, Dio? dio})
      : _baseUrl = baseUrl,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              // Riddle generation on a cold CPU Space genuinely can take a while.
              receiveTimeout: const Duration(seconds: 60),
              headers: {
                if (token != null && token.isNotEmpty)
                  'Authorization': 'Bearer $token',
              },
            ));

  final Dio _dio;
  final String _baseUrl;

  String get baseUrl => _baseUrl;

  /// Cheap liveness probe used to decide whether to offer cloud features.
  Future<bool> isReachable() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/health',
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      return r.statusCode == 200 && r.data?['status'] == 'ok';
    } on Object {
      return false;
    }
  }

  /// Identify a plant with the larger cloud model.
  Future<IdentificationResult> identify(
    Uint8List imageBytes, {
    String filename = 'scan.jpg',
    int topK = 5,
  }) async {
    final catalog = SpeciesCatalog.instance;
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(imageBytes, filename: filename),
      });
      final r = await _dio.post<Map<String, dynamic>>(
        '/identify',
        data: form,
        queryParameters: {'top_k': topK},
      );

      final body = r.data;
      if (body == null) throw const PlantGoApiException('empty response');

      final raw = (body['predictions'] as List?) ?? const [];
      final predictions = <PlantPrediction>[];
      for (final entry in raw) {
        final map = entry as Map<String, dynamic>;
        final species = catalog.byScientificName(map['scientific_name'] as String);
        // A species the app does not know about means the server is running a
        // newer model than this build ships labels for; skip rather than crash.
        if (species == null) continue;
        predictions.add(PlantPrediction(
          species: species,
          confidence: (map['confidence'] as num).toDouble(),
        ));
      }
      if (predictions.isEmpty) {
        throw const PlantGoApiException(
          'server returned no species this app build recognises',
        );
      }

      return IdentificationResult(
        predictions: predictions,
        source: 'cloud',
        inferenceMs: (body['inference_ms'] as num?)?.toInt() ?? 0,
      );
    } on DioException catch (e) {
      throw PlantGoApiException(_describe(e));
    }
  }

  /// Generate a riddle for [scientificName].
  ///
  /// The server validates the riddle (4 lines, ends in a question, does not name
  /// the plant) and retries internally; [RiddleResult.valid] reports whether it
  /// managed it, so the caller can fall back rather than show a broken puzzle.
  Future<RiddleResult> generateRiddle({
    required String scientificName,
    double temperature = 0.8,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/riddle',
        data: {
          'scientific_name': scientificName,
          'temperature': temperature,
        },
      );
      final body = r.data;
      if (body == null) throw const PlantGoApiException('empty response');
      return RiddleResult(
        riddle: body['riddle'] as String? ?? '',
        scientificName: body['scientific_name'] as String? ?? scientificName,
        commonName: body['common_name'] as String? ?? '',
        valid: body['valid'] as bool? ?? false,
        attempts: (body['attempts'] as num?)?.toInt() ?? 1,
        generationMs: (body['generation_ms'] as num?)?.toInt() ?? 0,
      );
    } on DioException catch (e) {
      throw PlantGoApiException(_describe(e));
    }
  }

  String _describe(DioException e) {
    final code = e.response?.statusCode;
    final detail = e.response?.data is Map
        ? (e.response!.data as Map)['detail']?.toString()
        : null;
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError =>
        'could not reach the PlantGo API at $_baseUrl',
      DioExceptionType.receiveTimeout => 'the API took too long to respond',
      _ when code == 401 => 'API rejected the token',
      _ when code == 503 => detail ?? 'the model is not available on the server',
      _ => detail ?? 'API error${code != null ? ' ($code)' : ''}',
    };
  }

  void close() => _dio.close(force: true);
}

class RiddleResult {
  const RiddleResult({
    required this.riddle,
    required this.scientificName,
    required this.commonName,
    required this.valid,
    required this.attempts,
    required this.generationMs,
  });

  final String riddle;
  final String scientificName;
  final String commonName;

  /// False when the model could not produce a well-formed riddle in its retries.
  final bool valid;
  final int attempts;
  final int generationMs;

  List<String> get lines =>
      riddle.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
}

class PlantGoApiException implements Exception {
  const PlantGoApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

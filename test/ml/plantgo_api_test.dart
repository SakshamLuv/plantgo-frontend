import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plantgo/ml/plantgo_api.dart';
import 'package:plantgo/ml/species_catalog.dart';

/// Minimal stub transport so the client is tested without a server.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
    ResponseBody.fromString(
      _encode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

String _encode(Object o) => const JsonEncoderShim().convert(o);

/// Tiny shim so the test file does not need dart:convert imported twice.
class JsonEncoderShim {
  const JsonEncoderShim();
  String convert(Object o) => _stringify(o);
  static String _stringify(Object? o) {
    if (o is Map) {
      return '{${o.entries.map((e) => '"${e.key}":${_stringify(e.value)}').join(',')}}';
    }
    if (o is List) return '[${o.map(_stringify).join(',')}]';
    if (o is String) return '"${o.replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
    return '$o';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SpeciesCatalog.resetForTest();
    await SpeciesCatalog.load();
  });

  final imageBytes = Uint8List.fromList(List.filled(64, 7));

  group('PlantGoApi.identify', () {
    test('maps server predictions onto the local species catalog', () async {
      final adapter = _StubAdapter((_) async => _json({
            'predictions': [
              {
                'scientific_name': 'Ficus religiosa',
                'common_name': 'Peepal',
                'category': 'sacred_tree',
                'confidence': 0.91,
              },
              {
                'scientific_name': 'Ficus benghalensis',
                'common_name': 'Bar (Banyan)',
                'category': 'sacred_tree',
                'confidence': 0.05,
              },
            ],
            'is_confident': true,
            'inference_ms': 812,
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      final result = await api.identify(imageBytes);

      expect(result.source, 'cloud');
      expect(result.inferenceMs, 812);
      expect(result.predictions, hasLength(2));
      expect(result.top!.species.scientificName, 'Ficus religiosa');
      expect(result.top!.confidence, closeTo(0.91, 1e-9));
      expect(result.isConfident, isTrue);
      // The species object comes from the local catalog, so it carries the
      // content the server never sends.
      expect(result.top!.species.hazard, Hazard.none);
      expect(result.top!.species.visualFeatures, isNotEmpty);
    });

    test('skips species this app build does not know about', () async {
      final adapter = _StubAdapter((_) async => _json({
            'predictions': [
              {
                'scientific_name': 'Newly Added species',
                'common_name': 'Future Plant',
                'confidence': 0.99,
              },
              {
                'scientific_name': 'Tagetes erecta',
                'common_name': 'Sayapatri (Marigold)',
                'confidence': 0.4,
              },
            ],
            'inference_ms': 100,
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      final result = await api.identify(imageBytes);

      // A server running a newer model must not crash an older app.
      expect(result.predictions, hasLength(1));
      expect(result.top!.species.scientificName, 'Tagetes erecta');
    });

    test('throws when no returned species is recognised', () async {
      final adapter = _StubAdapter((_) async => _json({
            'predictions': [
              {'scientific_name': 'Nope nope', 'confidence': 0.9},
            ],
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      await expectLater(
        api.identify(imageBytes),
        throwsA(isA<PlantGoApiException>()),
      );
    });

    test('turns a 503 into a readable message', () async {
      final adapter = _StubAdapter(
          (_) async => _json({'detail': 'plant model not found'}, status: 503));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      await expectLater(
        api.identify(imageBytes),
        throwsA(isA<PlantGoApiException>().having(
            (e) => e.message, 'message', contains('plant model not found'))),
      );
    });

    test('reports an unreachable host without leaking Dio internals', () async {
      final adapter = _StubAdapter((options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      await expectLater(
        api.identify(imageBytes),
        throwsA(isA<PlantGoApiException>()
            .having((e) => e.message, 'message', contains('could not reach'))),
      );
    });
  });

  group('PlantGoApi.generateRiddle', () {
    test('parses a valid riddle and splits it into lines', () async {
      const riddle = 'I stand where prayers are said each day\n'
          'My leaves shake though no hand sways\n'
          'My bark is smooth, my figs are small\n'
          'What tree am I beside the wall?';

      final adapter = _StubAdapter((_) async => _json({
            'riddle': riddle,
            'common_name': 'Peepal',
            'scientific_name': 'Ficus religiosa',
            'valid': true,
            'attempts': 1,
            'generation_ms': 2400,
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      final result = await api.generateRiddle(scientificName: 'Ficus religiosa');

      expect(result.valid, isTrue);
      expect(result.attempts, 1);
      expect(result.lines, hasLength(4));
      expect(result.lines.last, endsWith('?'));
    });

    test('surfaces valid=false so the caller can fall back', () async {
      final adapter = _StubAdapter((_) async => _json({
            'riddle': 'only one line',
            'common_name': 'Peepal',
            'valid': false,
            'attempts': 4,
            'generation_ms': 9000,
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      final result = await api.generateRiddle(scientificName: 'Ficus religiosa');

      expect(result.valid, isFalse);
      expect(result.attempts, 4);
    });

    test('sends the scientific name the server expects', () async {
      final adapter = _StubAdapter((_) async => _json({
            'riddle': 'a\nb\nc\nd?',
            'common_name': 'Sisnu',
            'valid': true,
            'attempts': 1,
            'generation_ms': 10,
          }));

      final api = PlantGoApi(baseUrl: 'https://example.test', dio: _dioWith(adapter));
      await api.generateRiddle(scientificName: 'Urtica dioica', temperature: 0.9);

      final sent = adapter.seen.single;
      expect(sent.path, '/riddle');
      expect(sent.data['scientific_name'], 'Urtica dioica');
      expect(sent.data['temperature'], 0.9);
    });
  });

  group('PlantGoApi.isReachable', () {
    test('true only when health reports ok', () async {
      final ok = PlantGoApi(
        baseUrl: 'https://example.test',
        dio: _dioWith(_StubAdapter((_) async => _json({'status': 'ok'}))),
      );
      expect(await ok.isReachable(), isTrue);

      final down = PlantGoApi(
        baseUrl: 'https://example.test',
        dio: _dioWith(_StubAdapter((options) async =>
            throw DioException(requestOptions: options, type: DioExceptionType.connectionError))),
      );
      expect(await down.isReachable(), isFalse);
    });
  });

  group('auth header', () {
    test('bearer token is attached when provided', () async {
      final adapter = _StubAdapter((_) async => _json({'status': 'ok'}));
      final dio = Dio(BaseOptions(
        baseUrl: 'https://example.test',
        headers: {'Authorization': 'Bearer tok3n'},
      ))
        ..httpClientAdapter = adapter;

      await PlantGoApi(baseUrl: 'https://example.test', dio: dio).isReachable();
      expect(adapter.seen.single.headers['Authorization'], 'Bearer tok3n');
    });
  });
}

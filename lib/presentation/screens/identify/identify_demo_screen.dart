import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../ml/identification_service.dart';
import '../../../ml/plant_classifier.dart';
import '../../../ml/riddle_repository.dart';
import '../../../ml/species_catalog.dart';

/// End-to-end demonstration of the PlantGo pipeline in one screen:
/// photo -> species -> riddle.
///
/// Deliberately self-contained (no BLoC, no DI) so it can be pushed from
/// anywhere and used to show the trained model working on a real device.
class IdentifyDemoScreen extends StatefulWidget {
  const IdentifyDemoScreen({super.key, this.apiBaseUrl, this.apiToken});

  final String? apiBaseUrl;
  final String? apiToken;

  @override
  State<IdentifyDemoScreen> createState() => _IdentifyDemoScreenState();
}

class _IdentifyDemoScreenState extends State<IdentifyDemoScreen> {
  IdentificationService? _service;
  RiddleRepository? _riddles;

  String? _startupError;
  bool _busy = false;
  String _status = 'Loading models…';

  File? _photo;
  IdentificationResult? _result;
  Riddle? _riddle;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final service = await IdentificationService.create(
        apiBaseUrl: widget.apiBaseUrl,
        apiToken: widget.apiToken,
      );
      final riddles = RiddleRepository(identification: service);
      if (!mounted) return;
      setState(() {
        _service = service;
        _riddles = riddles;
        _status = service.hasLocalModel
            ? 'On-device model ready'
            : 'On-device model missing — cloud only';
      });

      // Warming the riddle cache is an optimisation, so it must not gate the
      // UI: the asset bundle can hand back a permanently pending future for an
      // asset that is not bundled, which would leave this screen stuck on
      // "Loading models…" forever.
      riddles.warmCache();

      if (widget.apiBaseUrl != null) service.checkCloud();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _startupError = '$e');
    }
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    final service = _service;
    if (service == null || _busy) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 90,
    );
    if (picked == null) return;

    setState(() {
      _busy = true;
      _photo = File(picked.path);
      _result = null;
      _riddle = null;
      _error = null;
      _status = 'Identifying…';
    });

    try {
      final bytes = await picked.readAsBytes();
      final result = await service.identifyPhoto(Uint8List.fromList(bytes));
      if (!mounted) return;
      setState(() {
        _result = result;
        _status = 'Identified by ${result.source} in ${result.inferenceMs} ms';
      });

      final top = result.top;
      if (top != null && result.isUsable) {
        setState(() => _status = 'Writing your next riddle…');
        final riddle = await _riddles!.riddleFor(top.species);
        if (!mounted) return;
        setState(() {
          _riddle = riddle;
          _status = 'Identified by ${result.source} in ${result.inferenceMs} ms';
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _status = 'Identification failed';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PlantGo — identify'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _startupError != null
          ? _ErrorPane(message: _startupError!, onRetry: _boot)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusChip(text: _status, service: _service),
                const SizedBox(height: 16),
                if (_photo != null) _PhotoPreview(file: _photo!),
                if (_photo != null) const SizedBox(height: 16),
                if (_error != null) ...[
                  _ErrorPane(message: _error!),
                  const SizedBox(height: 16),
                ],
                if (_result != null) _ResultCard(result: _result!),
                if (_result != null) const SizedBox(height: 16),
                if (_riddle != null) _RiddleCard(riddle: _riddle!),
                if (_riddle != null) const SizedBox(height: 16),
                if (_result == null && _photo == null) const _EmptyHint(),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.service});

  final String text;
  final IdentificationService? service;

  @override
  Widget build(BuildContext context) {
    final s = service;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(
          avatar: const Icon(Icons.info_outline, size: 18),
          label: Text(text),
        ),
        if (s != null)
          Chip(
            avatar: Icon(
              s.hasLocalModel ? Icons.phone_android : Icons.phonelink_erase,
              size: 18,
            ),
            label: Text(s.hasLocalModel ? 'on-device' : 'no local model'),
          ),
        if (s != null && s.hasCloud)
          Chip(
            avatar: Icon(
              switch (s.lastKnownCloudState) {
                true => Icons.cloud_done_outlined,
                false => Icons.cloud_off_outlined,
                null => Icons.cloud_queue_outlined,
              },
              size: 18,
            ),
            label: const Text('cloud'),
          ),
      ],
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 1,
        child: Image.file(file, fit: BoxFit.cover),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final IdentificationResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = result.top;
    if (top == null) return const SizedBox.shrink();
    final species = top.species;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!result.isConfident)
            Container(
              width: double.infinity,
              color: theme.colorScheme.tertiaryContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                'Not a confident match — try filling more of the frame with '
                'the leaf or flower.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          if (species.isHazardous) _HazardBanner(species: species),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(top.label, style: theme.textTheme.headlineSmall),
                Text(
                  species.scientificName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _ConfidenceBar(value: top.confidence),
                const SizedBox(height: 4),
                Text(
                  '${(top.confidence * 100).toStringAsFixed(1)}% · '
                  '${result.source} · ${result.inferenceMs} ms',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _Fact(icon: Icons.place_outlined, text: species.habitat),
                _Fact(icon: Icons.lightbulb_outline, text: species.note),
                if (species.isInvasive)
                  _Fact(
                    icon: Icons.report_gmailerrorred_outlined,
                    text: 'Invasive species — worth reporting on the map.',
                  ),
                if (result.predictions.length > 1) ...[
                  const Divider(height: 28),
                  Text('Other possibilities',
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  ...result.predictions.skip(1).take(3).map(
                        (p) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${p.label}  ·  ${(p.confidence * 100).toStringAsFixed(1)}%',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HazardBanner extends StatelessWidget {
  const _HazardBanner({required this.species});

  final Species species;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toxic = species.hazard == Hazard.toxic;
    final bg = toxic ? theme.colorScheme.errorContainer : const Color(0xFFFFF3CD);
    final fg = toxic ? theme.colorScheme.onErrorContainer : const Color(0xFF6B4E00);

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(toxic ? Icons.dangerous_outlined : Icons.warning_amber_outlined,
              color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              species.safety,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = value >= IdentificationResult.confidentThreshold
        ? scheme.primary
        : value >= IdentificationResult.uncertainThreshold
            ? scheme.tertiary
            : scheme.error;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: 8,
        backgroundColor: scheme.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(colour),
      ),
    );
  }
}

class _RiddleCard extends StatelessWidget {
  const _RiddleCard({required this.riddle});

  final Riddle riddle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, icon) = switch (riddle.source) {
      RiddleSource.model => ('Phi-3 LoRA, live', Icons.auto_awesome),
      RiddleSource.cached => ('Phi-3 LoRA, cached', Icons.bookmark_outline),
      RiddleSource.composed => ('offline fallback', Icons.link_off),
    };

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Text('Your next riddle',
                    style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer)),
                const Spacer(),
                Text(label,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer
                            .withValues(alpha: 0.7))),
              ],
            ),
            const SizedBox(height: 12),
            ...riddle.lines.map(
              (l) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.4,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.local_florist_outlined,
              size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('Point the camera at a plant',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'The model knows ${SpeciesCatalog.isLoaded ? SpeciesCatalog.instance.count : 40} '
            'species found around Nepal.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Text('Something went wrong',
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer)),
              ],
            ),
            const SizedBox(height: 8),
            Text(message,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer)),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/lh_interpretation_model.dart';
import 'package:hercycle/core/lh_strip_cv_pipeline.dart';
import 'package:hercycle/models/lh_test_entry.dart';
import 'package:hercycle/providers/auth_user_provider.dart';

class LhEntryBottomSheet extends StatefulWidget {
  final String dateStr;
  final Function(LhTestEntry) onSaved;

  const LhEntryBottomSheet({
    super.key,
    required this.dateStr,
    required this.onSaved,
  });

  @override
  State<LhEntryBottomSheet> createState() => _LhEntryBottomSheetState();
}

class _LhEntryBottomSheetState extends State<LhEntryBottomSheet> {
  bool _isManual = false;
  bool _isLoading = false;
  LhManualResult _manualResult = LhManualResult.positive;
  String? _capturedImagePath;
  double? _scannedRatio;
  double? _scannedRaw;
  double? _scannedReliability;
  String? _scannedDetectionVersion;
  String? _scannedCalibrationVersion;
  String? _scannedInterpretationVersion;
  LhSurgeStatus _scannedSurge = LhSurgeStatus.low;
  String? _scanError;
  String? _scanErrorCode;
  final TextEditingController _notesController = TextEditingController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _isLoading = true;
      _scanError = null;
    });
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked != null) {
        final result = LhStripCvPipeline.analyzeStrip(imagePath: picked.path);
        if (result.success) {
          setState(() {
            _capturedImagePath = picked.path;
            _scannedRatio = result.tcRatio;
            _scannedRaw = result.rawRatio;
            _scannedReliability = result.reliability;
            _scannedDetectionVersion = result.detectionVersion;
            _scannedCalibrationVersion = result.calibrationVersion;
            _scannedInterpretationVersion = result.interpretationVersion;
            _scannedSurge = result.surgeStatus;
            _scanError = null;
            _scanErrorCode = null;
            _isLoading = false;
          });
        } else {
          setState(() {
            _scanError = result.errorMessage ?? 'Analysis failed. Please retry or use manual log.';
            _scanErrorCode = result.errorCode?.name;
            _isLoading = false;
          });
        }
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() {
        _scanError = 'Failed to capture image: $e';
        _isLoading = false;
      });
    }
  }

  void _save() async {
    final userId = safeCurrentUid();
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to save LH tests')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final baseDate = DateTime.tryParse(widget.dateStr) ?? DateTime.now();
    final now = DateTime.now();
    final timestamp = DateTime(baseDate.year, baseDate.month, baseDate.day, now.hour, now.minute);
    final id = 'lh_${timestamp.millisecondsSinceEpoch}';

    // Velocity is stored per-day (PRD §21). The pipeline helper returns the
    // legacy hourly shape, so convert. Manual entries carry no ratio and
    // therefore no velocity (PRD §27).
    double? velocityPerDay;
    try {
      final existing = await DatabaseRepository().getLhTests(userId, limit: 5);
      LhTestEntry? previousQuant;
      for (final e in existing) {
        if (e.tcRatio != null && e.entryType == LhEntryType.aiScan) {
          previousQuant = e;
          break;
        }
      }
      if (!_isManual && previousQuant != null && _scannedRatio != null) {
        final hourly = LhStripCvPipeline.calculateVelocity(
          previousQuant,
          LhTestEntry(
            id: id,
            userId: userId,
            timestamp: timestamp,
            entryType: LhEntryType.aiScan,
            calibratedRatio: _scannedRatio,
            surgeStatus: _scannedSurge,
          ),
        );
        if (hourly != null) {
          velocityPerDay = double.parse((hourly * 24.0).toStringAsFixed(3));
        }
      }
    } catch (_) {}

    final nowStamp = DateTime.now();
    LhTestEntry entry;
    if (_isManual) {
      final isPos = _manualResult == LhManualResult.positive;
      entry = LhTestEntry(
        id: id,
        userId: userId,
        timestamp: timestamp,
        entryType: LhEntryType.manual,
        manualResult: _manualResult,
        surgeStatus: isPos ? LhSurgeStatus.high : LhSurgeStatus.low,
        surgeVelocity: null,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        interpretationVersion: LhInterpretationModel.interpretationVersion,
        personalizationVersion: LhInterpretationModel.personalizationVersion,
        createdAt: nowStamp,
        updatedAt: nowStamp,
      );
    } else {
      entry = LhTestEntry(
        id: id,
        userId: userId,
        timestamp: timestamp,
        entryType: LhEntryType.aiScan,
        imageUrl: _capturedImagePath,
        rawRatio: _scannedRaw,
        calibratedRatio: _scannedRatio ?? 0.4,
        surgeStatus: _scannedSurge,
        surgeVelocity: velocityPerDay,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        reliability: _scannedReliability ?? 0.8,
        detectionVersion: _scannedDetectionVersion ?? LhInterpretationModel.detectionVersion,
        calibrationVersion:
            _scannedCalibrationVersion ?? LhInterpretationModel.calibrationVersion,
        interpretationVersion: _scannedInterpretationVersion ??
            LhInterpretationModel.interpretationVersion,
        personalizationVersion: LhInterpretationModel.personalizationVersion,
        createdAt: nowStamp,
        updatedAt: nowStamp,
      );
    }

    try {
      await DatabaseRepository().saveLhTest(userId, entry);
      widget.onSaved(entry);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving LH test: $e')),
      );
    }
  }

  Widget _signalBar(String label, double fraction) {
    final w = fraction.clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ),
        Expanded(
          child: Container(
            height: 10,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(5),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: w <= 0 ? 0.02 : w,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFC26D81),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Log LH Test — ${widget.dateStr}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Mode Segmented Switch
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => setState(() => _isManual = false),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('AI Strip Scan'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: !_isManual ? const Color(0xFFC26D81) : Colors.grey.shade200,
                      foregroundColor: !_isManual ? Colors.white : Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => setState(() => _isManual = true),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Manual Log'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isManual ? const Color(0xFFC26D81) : Colors.grey.shade200,
                      foregroundColor: _isManual ? Colors.white : Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (!_isManual) ...[
              // AI Scan View (PRD §9–10, §28, §34–35)
              if (_isLoading && _capturedImagePath == null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.pink.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: const Color(0xFFC26D81).withValues(alpha: 0.3),
                        width: 1.5),
                  ),
                  child: const Column(
                    children: [
                      CircularProgressIndicator(color: Color(0xFFC26D81)),
                      SizedBox(height: 12),
                      Text('Analyzing your LH test...',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      SizedBox(height: 6),
                      Text('Detecting test lines / Measuring LH signal / Preparing your result',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ] else if (_capturedImagePath == null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.pink.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFC26D81).withValues(alpha: 0.3), width: 1.5),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.science_outlined, size: 48, color: Color(0xFFC26D81)),
                      const SizedBox(height: 12),
                      const Text(
                        'Scan your ovulation strip test',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Capture a photo or pick from gallery to compute the T/C ratio and surge velocity automatically.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: context.her.muted),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Keep the strip flat and fully visible / Use even lighting, avoid shadows and glare / Hold the camera parallel to the strip / No filters',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: context.her.muted, height: 1.5),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : () => _pickImage(ImageSource.camera),
                            icon: const Icon(Icons.camera_alt),
                            label: const Text('Camera'),
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC26D81), foregroundColor: Colors.white),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: _isLoading ? null : () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Gallery'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Result preview card (PRD §28)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          const SizedBox(width: 8),
                          const Text('LH Test Result', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setState(() {
                              _capturedImagePath = null;
                              _scannedRatio = null;
                            }),
                            child: const Text('Retake'),
                          ),
                        ],
                      ),
                      const Divider(),
                      Center(
                        child: Column(
                          children: [
                            Text(
                              _scannedRatio?.toStringAsFixed(2) ?? '--',
                              style: const TextStyle(
                                  fontSize: 40, fontWeight: FontWeight.bold, color: Color(0xFFC26D81)),
                            ),
                            const Text('T/C RATIO',
                                style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                              _scannedSurge.name.toUpperCase(),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: _scannedSurge == LhSurgeStatus.peak || _scannedSurge == LhSurgeStatus.high
                                    ? Colors.pink.shade700
                                    : Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _signalBar('TEST LINE', (_scannedRatio ?? 0).clamp(0.0, 2.0) / 2.0),
                      const SizedBox(height: 6),
                      _signalBar('CONTROL LINE', 1.0),
                      if (_scannedReliability != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Analysis reliability ${(_scannedReliability! * 100).round()}% — a tracking aid, not a diagnosis.',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ),
                      if (_scannedSurge == LhSurgeStatus.high || _scannedSurge == LhSurgeStatus.peak)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('High surge detected (ratio >= 0.8). Ovulation window will shift 24-36h!', style: TextStyle(fontSize: 12, color: Colors.pink)),
                        ),
                    ],
                  ),
                ),
              ],
              if (_scanError != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_scanErrorCode == 'controlLineMissing')
                        const Text('Control line not detected',
                            style: TextStyle(
                                color: Colors.red,
                                fontSize: 14,
                                fontWeight: FontWeight.bold)),
                      Text(_scanError!,
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : () => _pickImage(ImageSource.camera),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retake Photo'),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFC26D81),
                                foregroundColor: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: () => setState(() {
                              _scanError = null;
                              _isManual = true;
                            }),
                            child: const Text('Log Manually'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ] else ...[
              // Manual Log View
              const Text('Select Test Result:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Positive (Surge)'),
                      selected: _manualResult == LhManualResult.positive,
                      onSelected: (val) => setState(() => _manualResult = LhManualResult.positive),
                      selectedColor: const Color(0xFFC26D81).withValues(alpha: 0.2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Negative (Low)'),
                      selected: _manualResult == LhManualResult.negative,
                      onSelected: (val) => setState(() => _manualResult = LhManualResult.negative),
                      selectedColor: Colors.grey.shade300,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_manualResult == LhManualResult.positive)
                const Text('⚡ Manual Positive triggers high surge status and 24-36h ovulation shift.', style: TextStyle(fontSize: 12, color: Colors.pink)),
            ],

            const SizedBox(height: 20),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'Time of test, brand, or symptoms...',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC26D81),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Save LH Test Record', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

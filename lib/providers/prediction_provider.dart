import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/prediction_service.dart';
import 'package:hercycle/providers/auth_user_provider.dart';

final predictionServiceProvider = Provider((ref) => PredictionService());

final predictionProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  // Watch auth state so account switches refetch instead of serving the
  // previous account's cached predictions.
  // valueOrNull: a loading/erroring auth stream degrades to the
  // logged-out message instead of failing this provider.
  final userId = ref.watch(authUserProvider).valueOrNull?.uid;
  if (userId == null) return {'message': 'User not logged in'};
  return ref.read(predictionServiceProvider).getPredictions(userId);
});

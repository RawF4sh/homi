import 'assessment_location.dart';
import 'home_safety/home_safety.dart';

/// Stable device-only capture slots for the legacy assessment's places.
/// These are never server room IDs and must not be sent to room/scan APIs.
abstract final class LocalPlaceRooms {
  static final List<RoomInstance> all = List.unmodifiable([
    for (final type in AssessmentLocation.values)
      RoomInstance(id: 'device-area-${type.name}', type: type, name: null),
  ]);

  static bool contains(RoomInstance? room) =>
      room != null && containsId(room.id);

  static bool containsId(String id) => all.any((r) => r.id == id);

  static String homeKey(String caseId) => 'assessment:$caseId:place-home';
}

/// The same ordered destinations are used before and after selecting a plan.
enum HomiDestination { plan, rooms, help, tasks, settings }

/// Stable identifiers only; callers must revalidate selection and permissions.
class HomiTarget {
  const HomiTarget(
    this.destination, {
    this.caseId,
    this.roomId,
    this.findingId,
    this.programId,
    this.taskId,
  });
  final HomiDestination destination;
  final String? caseId, roomId, findingId, programId, taskId;
}

enum FeatureAvailability {
  configuredOff,
  supported,
  unsupportedDevice,
  backendUnavailable,
  temporarilyUnavailable,
}

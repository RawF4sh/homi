import '../application/assessment_flow.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/image/image_validator.dart';
import '../domain/measurement/measurement_input.dart';
import '../domain/review/finding_review_state.dart';

abstract final class AssessmentCopy {
  static const String notSavedYet =
      'Not saved yet. Lost if the app closes before you save.';

  static String areaTitle(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => 'Bathroom',
    AssessmentArea.entrance => 'Entrance',
  };

  static String areaExplanation(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => 'Route to the tub, shower or toilet.',
    AssessmentArea.entrance => 'Approach, doorway or threshold.',
  };

  static String viewPrompt(AssessmentArea area, CaptureView view) =>
      switch ((area, view)) {
        (AssessmentArea.bathroom, CaptureView.overview) =>
          'Take a wide photo of the route to the tub, shower or toilet.',
        (AssessmentArea.bathroom, CaptureView.closeUp) =>
          'Take a closer photo of the hard-to-see part.',
        (AssessmentArea.entrance, CaptureView.overview) =>
          'Take a photo of the approach and doorway.',
        (AssessmentArea.entrance, CaptureView.closeUp) =>
          'Take a closer photo of the threshold or doorway edge.',
      };

  static String safetyNote(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom =>
      'Stay on a dry floor. Don’t climb, stand in the tub or move heavy things.',
    AssessmentArea.entrance => 'Don’t climb or move heavy things.',
  };

  static const String privacyCheck =
      'Cover or retake if it shows faces, mail, addresses, medicine labels or '
      'rooms you don’t want to share.';

  static const String privacyDetail =
      'Removing hidden photo data does not hide what is visible in the '
      'picture.';

  static const String markAfterSaving =
      'You can mark the area after the photo is saved.';

  static String? notice(FlowNotice? notice) => switch (notice) {
    null => null,
    CaptureCancelledNotice() =>
      'No photo was taken. You can try again or continue without a photo.',
    PermissionNotice(canAskAgain: true) =>
      'Camera access was not allowed. You can try again or continue without '
          'a photo.',
    PermissionNotice(canAskAgain: false) =>
      'Camera access is turned off for this app. To take photos, allow it in '
          'your phone settings, then tap "I changed the setting". You can also '
          'continue without a photo.',
    CameraUnavailableNotice() =>
      'The camera is not available right now. You can continue without a '
          'photo.',
    PhotoRejectedNotice(:final reason) => rejected(reason),
    CaptureFailedNotice() =>
      'Something went wrong taking the photo. Please try again.',
    PhotoImportFailedNotice(timedOut: true) =>
      'The selected photo took too long to become available. Open it in Photos to download it, then try again. You can choose another photo or continue without one.',
    PhotoImportFailedNotice(timedOut: false) =>
      'The selected photo could not be imported. Try again or choose another photo. You can continue without one.',
    PhotoPreviewUnavailableNotice() =>
      'The photo was captured, but its preview could not be opened. Reopen this finding to retry, or retake or remove the photo.',
    PhotoRemovedNotice() => 'Photo removed.',
    InterruptedCaptureNotice() =>
      'The last photo attempt was interrupted. No unfinished camera or library result was attached. Your earlier photo and measurements are kept. Take or choose the photo again, or continue without a new one.',
    InterruptedPrivacyNotice() =>
      'The photo editor was interrupted before its changes were saved. Unfinished crops and covers were not applied. Review the retained photo and apply the privacy edits again before saving online.',
    PrivatePhotoSaveFailedNotice() =>
      'The private photo checkpoint could not be saved. Keep this screen open and free some device space, then try again. Your previous saved photo is retained.',
    PhotoTargetChangedNotice() =>
      'This finding or photo changed while the photo step was open. The returned photo was not attached. Review the current finding before trying again.',
    PhotoCaptureLimitNotice() =>
      'This assessment has reached its photo-attempt limit. Your saved work is retained. Continue with the existing photos or without a new photo; freeing device space will not reset this limit.',
  };

  static String rejected(ImageRejection reason) => switch (reason) {
    ImageRejection.heif =>
      'This photo is in HEIC format, which cannot be used yet. Take another '
          'photo, or set your camera to save "Most Compatible" (JPEG) photos.',
    ImageRejection.tooManyBytes =>
      'This photo is larger than 8 MB. Take another photo at a lower '
          'resolution.',
    ImageRejection.edgeTooLong || ImageRejection.tooManyPixels =>
      'This photo has too many pixels to use. Take another photo at a lower '
          'resolution.',
    ImageRejection.empty ||
    ImageRejection.unsupportedFormat ||
    ImageRejection.unreadableDimensions ||
    ImageRejection.zeroDimension =>
      'This photo could not be read. Please take another.',
  };

  static const String observationLabel = 'What do you notice?';
  static const String observationHint =
      'For example, “a raised threshold”. Note anything unknown too.';
  static const String observationRequired =
      'Describe what you notice before continuing.';

  static const String measurementsIntro =
      'Optional. Leave blank if not measured. Enter 0 only if you measured '
      'and found nothing.';

  static String measurementError(LengthParseError error) => switch (error) {
    LengthParseError.empty => 'Enter a number or leave it empty.',
    LengthParseError.notANumber => 'Enter digits only, like 80 or 80.5.',
    LengthParseError.negative => 'Measurements cannot be negative.',
    LengthParseError.unexpectedSeparator =>
      'Use one decimal mark and no thousands separator, like 1500 or 80.5.',
    LengthParseError.tooManyDigits => 'That number is too long. Check it.',
    LengthParseError.tooManyDecimals => 'Use at most 4 decimal places.',
  };

  static const String estimateLabel = 'This is my estimate, not a measurement';

  static String reviewState(FindingReviewState state) => switch (state) {
    FindingReviewState.needsReview => 'Needs your review',
    FindingReviewState.confirmed => 'Confirmed by you',
    FindingReviewState.dismissed => 'Dismissed',
  };

  static const String confirmMeaning =
      'Confirming means you checked this record. It is not an inspection, '
      'diagnosis or program decision.';

  static const String anotherViewRequested =
      'You asked for another photo of this finding.';

  static const String noPhotos = 'No photo for this finding.';

  static const String zeroCheck = 'You entered 0. Is that right?';
}

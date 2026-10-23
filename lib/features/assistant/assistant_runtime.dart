import 'assistant_model.dart';
import 'local_assistant_model.dart';

/// Trial selection is explicit at build time, with no automatic provider switch.
const localAssistantTrial = bool.fromEnvironment('HOMI_LLAMA_TRIAL');
AssistantModel assistantRuntime() => localAssistantTrial
    ? const LocalAssistantModel()
    : const OnDeviceAssistantModel();

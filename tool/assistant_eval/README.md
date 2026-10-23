# Homi assistant evaluation tools

Read [the procedure and scoring rubric](../../docs/homi-assistant-evaluation.md).

- `matrix.json`: 16 fictional scenarios × 6 app locales.
- `context_fixtures.dart`: inputs built with the real B1 context factory.
- `evaluate.py`: dependency-free frozen-request preparation, empty run templates, recorded-response reports, and paired-device candidate comparison. It never invokes a model or a network.
- `test_evaluate.py`: synthetic tests of reporting logic, not candidate results.
- `../../test/features/assistant/evaluation/context_matrix_test.dart`: production contract, privacy/action, localization checks, and optional context export.

Do not store candidate results in this folder. Use ignored local artifacts. Missing evidence prevents acceptance; no actual model candidate has been measured by these files.

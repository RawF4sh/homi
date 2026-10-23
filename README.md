# Safe at Home

An iPhone and Android app for reviewing home safety concerns, comparing possible assistance programs and preparing draft applications. Built with Flutter/Dart, native Apple/Android capture, a Node/TypeScript API and Supabase Auth/PostgreSQL.

The team beta uses fictional cases. Program matches are not approvals, scans are not professional assessments, and application packets remain drafts.

## Run locally

Use the team's Flutter 3.41.5 / Dart 3.11.3 toolchain and Node 24.12 or later. Install Xcode for iOS or the Android SDK for Android, then check the device setup with `flutter doctor`.

```sh
flutter pub get
npm --prefix backend ci --ignore-scripts
flutter run
```

The default build opens bundled fictional examples. To use the connected app, supply an ignored configuration file with `SAH_LIVE_BACKEND`, `SAH_API_URL`, `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`:

```sh
flutter run --dart-define-from-file=backend/local-artifacts/mobile-config.json
```

Set `SAH_LIVE_BACKEND` to `true`. The API URL must identify the configured HTTPS backend. Enable optional feature flags only after the corresponding backend setup is complete. Database passwords and elevated keys never belong in a mobile configuration file.

For the core feature profile, save the authenticated `/v1/capabilities` response
in an ignored file and use the checked build wrapper:

```sh
python3 tool/build_homi_core.py --platform ios --config backend/local-artifacts/mobile-config.json --capabilities backend/local-artifacts/capabilities.json
```

Use `--platform apk` or `appbundle` for Android. Older services can use
`--readiness` with an authenticated read-probe report for the same API origin,
no more than 24 hours old. Missing evidence or a capabilities 404 does not enable
features. The wrapper validates before building; it does not install or deploy.
Neither evidence format proves writes, exports or physical-device acceptance.
Keep private configuration, tokens and raw case responses out of logs.

See [Android setup](docs/android-local-setup.md), [backend setup](backend/README.md) and [account configuration](docs/public-account-access.md) for platform and server details.

## Checks

After resolving dependencies, run:

```sh
bash tool/verify_project.sh all
```

This runs the existing Flutter, backend and shared HTTP checks. [Installed-app checks](integration_test/README.md), native builds, physical-device capture and hosted verification are separate.

## Shared references

- [Contracts v1](contracts/v1/README.md), [v2](contracts/v2/README.md) and [v3](contracts/v3/README.md): case data, assessments, drafts, rooms and sharing.
- [Scanning](docs/bathroom-scanning.md): Apple LiDAR/ARKit and Android ARCore integration.
- [Program sources](docs/program-verification/): source reviews and unresolved requirements.
- [Operations and recovery](docs/maintenance-and-recovery.md): maintenance controls, backups and restore limits.
- [PDF viewer patch](third_party/pdfrx/PATCHES.md), [font license/build notes](backend/assets/fonts/README.md) and [form provenance](backend/assets/forms/README.md): required bundled assets.

Commit source code, tests, migrations, lockfiles and essential technical references. Keep plans, reports, team guides, wireframes, backups and personal tool settings local. Do not commit resident data, credentials or generated private packets. Development stays within the team's $0 out-of-pocket budget.

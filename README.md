# Safe at Home

The `integration/ios-beta` working tree contains the integrated Flutter app, native camera/media bridges and Node/TypeScript backend. See [iOS beta implementation and validation](docs/ios-beta-implementation.md) for setup, current test results and remaining device/cloud gates. This is a team beta using fictional cases; applications remain incomplete drafts.

A Flutter app for iPhone and Android that helps residents document home concerns, explore possible assistance programs, and prepare draft applications.

Without private connection configuration the app opens the labelled fictional demo. The configured app supports Supabase sign-in, saved cases, encrypted offline work, photo/manual assessment, program-specific intake and form review, PDF preview/sharing, manual history and deletion. The three-route backend bundle supports SCFHP and HPSM referral drafts plus an RTP preparation worksheet, with unresolved rules and professional decisions visibly preserved. Additive [v2 contracts](contracts/v2/README.md) coexist with the strict [v1 contracts](contracts/v1/README.md). Run `bash tool/verify_project.sh all` for local checks; deployment and physical-device acceptance are separate.

See [getting started and first commits](docs/getting-started.md) for run commands, the two local work areas and the manual commit order.

## Team setup

| Area | Owner | Handoff |
| --- | --- | --- |
| App and integration | Person 1 | Profile/case data, shared UI, storage and result screens |
| Home assessment | Person 2 | Reviewed findings, measurements and annotated evidence |
| Benefits and applications | Person 3 | Program rules, explained matches and draft packets |

Flutter/Dart is the team's chosen mobile framework. See [framework and backend recommendation](docs/framework.md) for the proposed architecture and first milestone.

Start development with the [Person 3 backend implementation plan](docs/backend-implementation-plan.md) and the [three-person Git worktree and integration workflow](docs/team-workflow.md). The workflow covers separate computers, the shared baseline, each person's branch, and human-reviewed merges.

# Safe at Home

A Flutter app for iPhone and Android that helps residents document home concerns, explore possible assistance programs, and prepare draft applications.

The first shared slice is a Flutter iOS/Android app with three fictional program-result examples, v1 JSON contracts and typed Dart adapters. The examples are bundled locally; there is no live matching API or deployed backend.

See [getting started and first commits](docs/getting-started.md) for run commands, the two local work areas and the manual commit order.

## Team setup

| Area | Owner | Handoff |
| --- | --- | --- |
| App and integration | Person 1 | Profile/case data, shared UI, storage and result screens |
| Home assessment | Person 2 | Reviewed findings, measurements and annotated evidence |
| Benefits and applications | Person 3 | Program rules, explained matches and draft packets |

Flutter/Dart is the team's chosen mobile framework. See [framework and backend recommendation](docs/framework.md) for the proposed architecture and first milestone.

Start development with the [Person 3 backend implementation plan](docs/backend-implementation-plan.md) and the [three-person Git worktree and integration workflow](docs/team-workflow.md). The workflow covers separate computers, the shared baseline, each person's branch, and human-reviewed merges.

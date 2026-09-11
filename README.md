# Safe at Home

A Flutter app for iPhone and Android that helps residents document home concerns, explore possible assistance programs, and prepare draft applications.

The shared app has three fictional program-result examples, draft checklist previews, v1 JSON contracts and typed Dart API clients. The local backend supports authenticated matching and draft preparation with safe retries. The default screen uses bundled examples; no cloud backend or official PDF generator is deployed. See the [matching API handoff](docs/matching-api.md) and [draft checklist handoff](docs/packet-api.md) to run the complete local check.

See [getting started and first commits](docs/getting-started.md) for run commands, the two local work areas and the manual commit order.

## Team setup

| Area | Owner | Handoff |
| --- | --- | --- |
| App and integration | Person 1 | Profile/case data, shared UI, storage and result screens |
| Home assessment | Person 2 | Reviewed findings, measurements and annotated evidence |
| Benefits and applications | Person 3 | Program rules, explained matches and draft packets |

Flutter/Dart is the team's chosen mobile framework. See [framework and backend recommendation](docs/framework.md) for the proposed architecture and first milestone.

Start development with the [Person 3 backend implementation plan](docs/backend-implementation-plan.md) and the [three-person Git worktree and integration workflow](docs/team-workflow.md). The workflow covers separate computers, the shared baseline, each person's branch, and human-reviewed merges.

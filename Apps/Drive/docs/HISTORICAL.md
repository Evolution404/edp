# EDP Drive — Historical Document Index

Updated: 2026-09-03

This file separates historical evidence from current product authority.

## Current sources of truth

Read these for current work:

1. `STATUS.md`
2. `ARCHITECTURE.md`
3. `TESTING.md`
4. `RELEASE-CHECKLIST.md`
5. `FIRST-INSTALL-ACCEPTANCE.md` for detailed machine execution
6. `../../../docs/PROGRESS-2026-09-01-drive-stabilization-and-release.md` for active stabilization/release execution history

If a historical file conflicts with a current source above, the current source wins.

## Historical plans / trackers

The following files are intentionally retained as evidence of prior decisions and experiments, but are not current implementation specifications:

- `PLAN-TRACKER-2026-08-26.md`
- `PLAN-2026-08-28-self-signed-distribution.md`
- `PLAN-2026-08-29-fda-raw-access.md`
- `PLAN-2026-08-29-single-app-service-migration.md`

Their unchecked items must not be interpreted as current technical debt without revalidation against the current code and current tracker.

## Historical diagnostics

Files under `diagnostics/` preserve investigation evidence. Examples include:

- real-device captures;
- Direct MFMount investigation;
- Finder progress estimation;
- public EDP metadata research.

Diagnostics can explain why the current architecture exists, but they do not override current lifecycle/safety contracts.

## Root-level handoffs

Older root-level `docs/HANDOFF-*.md`, `docs/PLAN-*.md`, and `docs/PROGRESS-*.md` files describe specific historical phases. They remain in Git for traceability.

In particular, these former entry points are superseded:

- `../../../docs/HANDOFF-2026-08-29.md`
- `../../../docs/HANDOFF-2026-09-01-real-device-ebusy-finalization.md`

Do not resume work from a remembered SHA, BSD `diskN`, or historical experiment sequence in those files.

## Rules for future documentation

- New current product facts belong in one of the four current sources of truth.
- Investigation details belong in a dated diagnostic or tracker, not in `STATUS.md` unless they remain product-relevant.
- A completed handoff should be marked historical once a newer current source replaces it.
- Do not delete historical evidence solely to make current documentation shorter.

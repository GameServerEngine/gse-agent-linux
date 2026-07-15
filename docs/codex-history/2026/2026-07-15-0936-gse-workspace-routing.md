# Task

## User Request

Correct current GameServer Engine (GSE) branding and architecture documentation while preserving compatibility-sensitive `GSP` identifiers.

## Problem

The Linux agent README and operator guide used inconsistent product spelling for GameServer Engine.

## Root Cause

Product branding had moved to GameServer Engine (GSE), but a few current documentation introductions still used older or inconsistent wording.

## Repositories Inspected

- `/home/dev/Projects/GSP`
- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`

## Files Read

- `README.md`
- `docs/PANEL_INTEGRATION.md`
- `documentation/agent-guide.md`
- Panel architecture and storefront history docs relevant to workspace routing

## Files Changed

- `README.md`
- `documentation/agent-guide.md`
- `docs/codex-history/2026/2026-07-15-0936-gse-workspace-routing.md`

## Architecture Decisions

- Normalized the public product name to GameServer Engine (GSE).
- Retained `GSP` in install paths, script names, config keys, headers, screen prefixes, and runtime markers as compatibility identifiers.

## Validation Performed

- Verified repository status before edits.
- Searched current docs for product-name and compatibility-identifier uses.
- Reviewed final diff.
- Ran `git diff --check`.

## Git Commits

Repository

`/home/dev/Projects/GSP/GSP-Agent-Linux`

Commit

`Document GSE workspace repository boundaries`

Hash

Pending until commit creation; final immutable hash is reported in the task response.

## Remaining Work

None.

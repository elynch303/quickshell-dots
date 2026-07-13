---
name: AI usage / quota issue
about: Claude, Codex, or OpenCode usage display, quota windows, reset time, or backend timer problem
title: "[AI Usage]: "
labels: bug, ai-usage
---

## Which provider is affected?

- [ ] Claude Code
- [ ] OpenAI Codex
- [ ] OpenCode

## What is wrong?

<!-- Example: Codex shows Weekly only, but I expected a 5h reset. -->

## What should be shown?

<!-- Example: Codex Weekly 14% used, reset on 2026-07-19 21:07, no Spark bucket in the main UI. -->

## Current cache output

Please paste the relevant cache, if available:

```bash
python3 -m json.tool ~/.cache/codex-usage.json
python3 -m json.tool ~/.cache/claude-usage.json
python3 -m json.tool ~/.cache/opencode-usage.json
```

```json

```

## Backend status

```bash
systemctl --user status codex-usage.timer
systemctl --user status claude-usage.timer
systemctl --user status opencode-usage.timer
```

## Codex-specific checks

If this is about Codex, paste:

```text
/status
```

Before posting `/status`, remove or redact your email address, account identifier, session ID, and any private account details.

If you paste `~/.cache/codex-usage.json`, redact account-specific values first. Maintainers will interpret the cache schema.

## Notes

<!-- Do not include private tokens, OAuth credentials, or account secrets. -->

# Codex skill for Restic Station

An optional [Codex agent skill](https://developers.openai.com/codex/skills)
that teaches Codex to operate Restic Station through its own CLI: inspect
first, preview before writing, ask before anything destructive, and never
fall back to raw restic or touch a secret.

Nothing here is installed with Restic Station, and Restic Station does not
need it. An MCP server is not involved either: the skill only sequences
ordinary `restic-station` commands. Claude Code, other shell agents and
people can follow the same rules from the vendor-neutral guide,
[`docs/agent-operations.md`](../../docs/agent-operations.md), without
installing anything.

## What is here

- `skills/restic-station/SKILL.md`: the skill itself.
- `evals/fixtures.json`: prompt-to-command fixtures. For each kind of
  request (health, plan, backup, retention, purge, restore, secret, raw
  restic, cloud files, unsupported feature) they say which commands may run,
  in what order, where the user must authorize, and what must never run.
  `scripts/agent-skill-lint.sh` checks them, the skill and the guide against
  the helper's own `capabilities --json` on every CI run.

The skill needs a helper newer than v0.1.3, which has `capabilities`,
`backup dry-run`, `snapshots list` and `retention preview`.

## Install

Codex reads user skills from `~/.agents/skills` and follows symlinks. Link the
skill from a checkout of this repository, so a `git pull` keeps it up to date:

```console
$ mkdir -p ~/.agents/skills
$ ln -s "$PWD/integrations/codex/skills/restic-station" ~/.agents/skills/restic-station
```

Run this from the repository root. To pin a copy instead, use
`cp -R integrations/codex/skills/restic-station ~/.agents/skills/`.

The skill is deliberately **not** in this repository's own `.agents/skills`:
that would load an operating skill into every Codex session that works on the
code.

## Update

With a symlink, `git pull`. With a copy, remove it and copy again. Restart
Codex if the change does not appear.

## Uninstall

```console
$ rm ~/.agents/skills/restic-station
```

This removes the link (or, for a copy, `rm -r` the directory). Nothing else
was changed.

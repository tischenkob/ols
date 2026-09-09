---
name: rebase
description: Rebase the rols branch onto upstream/master and settle every upstream change that overlaps a fork feature. Use when the user says rebase, sync with upstream, pull upstream, or merge upstream.
---

# rebase

## 1. Preflight

```bash
git status --porcelain          # must be empty
git branch --show-current       # must print rols
git fetch upstream
OLD=$(git merge-base upstream/master HEAD)
git log --oneline $OLD..upstream/master
git diff --stat $OLD upstream/master
```

Stop if the tree is dirty or the branch is not `rols`. If the log is empty, report "already up to date" and stop. Keep the log and diffstat as the range summary.

## 2. Rebase

```bash
git rebase upstream/master
```

On a conflict: `rols_*` files and regions under a `// rols:` marker are ours; unmarked regions are upstream's. Keep both sides when they touch different lines. When they touch the same lines inside a marked region, take upstream's structure and re-apply the fork's addition on top, then `git rebase --continue`. Record every conflicted file for step 3. If a conflict is not mechanical, `git rebase --abort`, report the file and hunk, stop.

## 3. Detect overlap

All against `$OLD..upstream/master`, compared with FORK.md and the tree.

```bash
git diff $OLD upstream/master -- misc/ols.schema.json | grep -o '^+.*"enable_[a-z_]*"' | grep -o 'enable_[a-z_]*'
git diff --name-status $OLD upstream/master -- src/server tests src/cli src/common | grep '^A'
git diff $OLD upstream/master -- src/server/action.odin src/server/requests.odin | grep '^+'
git diff $OLD upstream/master -- README.md | grep '^+- `enable_\|^+#'
ls src/server/rols_* tests/rols_*
```

- Config keys: a key listed in FORK.md "Fork-only config keys" is an overlap. Also flag a key whose stem matches a fork key with a different suffix, such as `enable_inlay_hints_range` against `enable_inlay_hints_range_types`.
- Files: for an added `dir/x.odin`, an existing `dir/rols_x.odin` is an overlap. Also compare the feature word (`lint_*`, `action_*`, `*_test`) against the `ls` output.
- Registrations: added `action_procs` entries and `call_map` keys. A key in FORK.md "Fork-only LSP requests", or an action whose name matches a `rols_action_*.odin` file, is an overlap.
- README: added option bullets and headings, matched against the FORK.md keys and "Fork sections in README.md".
- Hook points: for each file under FORK.md "Hook points in upstream files", run `git diff $OLD upstream/master -- FILE`. A hunk whose `@@` context names a proc carrying a `// rols:` marker, or that lands inside a marked region, is an overlap. Files that conflicted in step 2 are overlaps too.

## 4. Report and ask

Print one table in chat: feature, ours (files, keys, tests), theirs (files, keys, tests, commit), kind (same key / same file / same request / touched marked region).

Then AskUserQuestion per row, up to four rows per call, options `Drop ours`, `Keep ours`, `Merge`, each with one line of consequence.

## 5. Act

Drop ours:

- `git rm` the `rols_*` file and its `tests/rols_*_test.odin`.
- Remove the key from `src/common/config.odin`, `src/server/types.odin`, both places in `src/server/requests.odin`, `misc/ols.schema.json`, `README.md`.
- Remove the `action_procs` or `call_map` entry, and any `// rols:` marker whose region is now empty.
- Delete the FORK.md lines.

Keep ours:

- Remove only upstream's registration: its `action_procs` or `call_map` entry, or its schema and README key.
- Keep upstream's file in the tree so later rebases stay cheap.
- Put `// rols: replaced by rols_<x>.odin` at the removed registration.
- Add a line under FORK.md "Hook points in upstream files" naming the disabled upstream feature.

Merge: change nothing now. Add a line under a FORK.md `## Pending merges` heading naming both sides.

## 6. Verify and commit

```bash
./build.sh && ./build.sh test && tools/cli_smoke.sh
./odinfmt -config:odinfmt.json -w FILE   # only files edited in step 5
```

Re-run the key-list command from FORK.md "Fork-only config keys" and make the FORK.md list match its output.

One commit per decision: `Drop <feature>: upstream ships it` or `Keep rols <feature> over upstream <feature>`.

Final report: range summary, decisions, pending merges, test result.

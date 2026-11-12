# Working in this repository

This is a soft fork of Zig. It exists to carry fixes for defects that cannot
get fixed upstream. Every fix should be tightly scoped and prove itself: a
reproduction before, a test or command that shows the fix after, and a written
record in `defects/`.

Upstream is `ziglang/zig` on Codeberg. This fork is `sargunv/zig-fixes` on
GitHub. This file, `mise.toml`, `defects/`, and the fix commits are the only
things that are ours.

## Hard rules

- **Never post upstream.** No issues, pull requests, comments or reactions on
  ziglang's Codeberg or GitHub. Upstream does not accept LLM-assisted
  contributions, and this fork is LLM-maintained. Reading their tracker and
  repository is fine.
- **Never rewrite the history of a line branch** (see Branches).

## Scope

The fork carries defect fixes only. A program that compiles with upstream's
release must compile and behave the same with ours, apart from the defect that
was fixed.

- No features, language changes, API changes, refactors, renames or
  reformatting. Every changed line is a line that can conflict with upstream
  from then on.
- Keep each fix to the smallest diff that correctly and idiomatically removes
  the defect.
- If upstream has already fixed the defect on another branch, take their fix
  with `git cherry-pick -x` instead of writing one. The next merge is then
  trivial.
- Follow upstream's style in the code you touch, and run `zig fmt` on it.

## Branches

`origin` is this fork on GitHub. `upstream` is Zig on Codeberg
(`https://codeberg.org/ziglang/zig`) and is read-only.

| Branch | What it is |
|---|---|
| `upstream/*` | Upstream's branches. |
| `fork/0.17.x` | The current line: upstream's `0.17.x` release branch plus our fixes. This is what gets built and used. It is the repository's default branch. |
| `fix/<slug>` | Work on one entry. Branch from the line, one git worktree per branch. |

A fix lands on the line as **one squash commit**. The only merge commits on a
line are merges of upstream. That keeps
`git log --first-parent --no-merges upstream/0.17.x..fork/0.17.x` an exact
list of what we carry.

A fix is proposed as a pull request from `fix/<slug>` to the line, and
squash-merged. The branch may hold any number of commits. Whoever merges gives
the squash commit the fix's message and trailers, in the format under Commits.
GitHub's default squash message is only right when the pull request holds a
single commit. The pull request's description is written for its reviewer. It
is not the commit message and carries no trailers, so check trailers on the
commits, not on the description.

## The backlog

`defects/README.md` describes the layout. In short: one markdown file per
defect, and the directory it sits in is its status.

- `found/` → `root-caused/` when the responsible code is cited as `path:line`,
  the mechanism is explained, and the defect is reproduced on the line (or the
  faulty code was read there).
- `found/` → `rejected/` when the defect is root caused but no correct focused
  fix will exist here.
- `root-caused/` → `fixed/` in the same commit as the fix.
- Move entries with `git mv`. Refer to an entry by its slug, never its path.
- An entry that turns out not to be a defect, or not to affect this line, is
  deleted in a commit whose message says why. If it came from upstream's
  tracker, update its row in `defects/upstream-triage.tsv` too.

### Fixing an entry

1. Confirm the root cause yourself. The existing text may be wrong; correct
   it if so.
2. Reproduce the defect and keep the command.
3. Fix it, within Scope.
4. Add a test where upstream's test suite can express one, in the place
   upstream keeps tests of that kind. Re-enable any test upstream skips
   because of this defect.
5. Run the entry's Verification, and the tests for the area you touched.
6. Move the entry to `fixed/` and fill in its `## Fix` section.

### New defects

Write an entry in `found/` from `defects/TEMPLATE.md`. An entry stands on its
own: the symptom, a reproduction, the responsible code. It does not say who
hit the defect or in which project. This directory is the fork's issue
tracker. Do not suggest reporting it upstream.

**From upstream's tracker:** a sweep reads upstream's open issues through the
Codeberg API and triages every issue that has no row in
`defects/upstream-triage.tsv` yet, by the priority rules in
`defects/README.md`. Each gets a row; priority 1 defects that affect this line
also get an entry. A sweep also checks the issues behind existing entries: one
that upstream has closed with a fix is a cherry-pick candidate.

## Commits

One commit does one thing. Subjects are lowercase after the prefix, in the
imperative, with no trailing period, as upstream writes them.

Every commit we author ends with an `Assisted-by:` trailer naming the tool and
model that wrote it, as the last trailer:

```
Assisted-by: <tool>; model: <provider>/<model>
```

Name the tool and model you are actually running as; do not guess. A merge of
upstream gets the trailer too. A commit cherry-picked from upstream does not,
unless it had to be changed to apply.

**Backlog only.** Prefix `defects:`. These never touch code.

```
defects: add atomics-64bit-on-32bit-targets
defects: root-cause cb37474-shared-cache-manifest-deadlock
defects: update ohos-libc-support
defects: sweep upstream issues
```

**A fix.** Upstream's `<area>: <change>` subject, a body that says what was
wrong and why this change corrects it, and a `Fix:` trailer with the slug.
The commit contains the code, the test, and the entry's move to `fixed/`.

```
link.MachO: skip rebases for subtractor relocation pairs

A pointer-sized `A - B` pair is a link-time constant, but a rebase was
emitted for it, so dyld slid the bytes at load time and corrupted
`__text`.

Fix: cb36848-macho-subtractor-rebase
Assisted-by: Claude Code; model: anthropic/claude-opus-5-5
```

**A fix taken from upstream.** `git cherry-pick -x`, keeping upstream's
message, then amend to add the `Fix:` trailer and the entry's move.

**A merge of upstream.** See below.

**Fork housekeeping** (this file, tooling of ours). Prefix `fork:`.

`git log --grep '^Fix: <slug>'` must find every commit that belongs to an
entry. Reverts use `git revert` and move the entry back.

## Merging upstream

Merge `upstream/0.17.x` into `fork/0.17.x` whenever it has moved, and always
at a point release. Merge; do not rebase.

1. `git fetch upstream`, then read `git log fork/0.17.x..upstream/0.17.x`.
   Note any incoming commit that fixes something in `defects/`.
2. `git merge upstream/0.17.x`.
3. Where upstream has fixed a defect we also fixed, take upstream's version
   and drop ours. Note it in the entry's `## Fix` section.
4. A conflict inside one of our fixes is a question, not a chore: has upstream
   changed the code the fix depends on? Decide from the entry, not from
   memory. If `rerere` is enabled in your clone, it may replay and stage an
   earlier resolution; review a replayed resolution like a new one. It is a
   convenience local to one clone, not the record. The merge commit and the
   entry are the record.
5. Re-run the Verification of every `fixed/` entry whose fix touches a file
   the merge changed.
6. Commit as `Merge upstream 0.17.x at <short sha>`. The body lists each
   conflict as `path: how it was resolved (slug)`, and each entry that
   upstream has now fixed. Write `No conflicts.` when there were none.

### Moving to a new release line

Do not merge a new minor release into the old line. Upstream's release
branches carry backports that conflict with their originals on `master`, and
none of those conflicts are ours to resolve. Start a new line instead:

1. Create `fork/<new>.x` from upstream's release tag or branch.
2. Bring `AGENTS.md`, `mise.toml` and `defects/` over from the old line in one
   `fork:` commit, and update the branch names in this file.
3. For each entry in `fixed/`: if the new base no longer has the defect,
   delete it. Otherwise re-apply it by cherry-picking the commits its `Fix:`
   trailer finds on the old line, and verify it again. If deferred for any
   reason, move it back to `root-caused/`.
4. Re-check `affects-line` on the open entries.
5. Make the new line the repository's default branch.

## Building and testing

`mise install` provides upstream's release of this line as `zig`.

- **A fix that only changes `lib/`** can be exercised with that release
  binary and this checkout's library directory:
  `zig <command> --zig-lib-dir lib`. `zig build` does not take that flag; set
  `ZIG_LIB_DIR` in the environment instead. Code under `lib/` that is compiled
  into the compiler itself (`lib/std/zig/`, `lib/std/Target*`, and whatever
  else `src/` imports) only takes effect in a compiler build.
- **A fix that changes `src/`** needs a compiler build. `mise run build`
  downloads upstream's prebuilt LLVM, Clang and LLD for this line on first
  use, builds `zig-out/bin/zig` with the release binary, and prints its
  version. It takes an optimization mode, `ReleaseSafe` by default;
  `mise run build Debug` also enables the compiler's debug commands. The
  built binary uses this checkout's `lib/`, so a later change under `lib/`
  needs no rebuild. A build takes a few minutes and about 10 GB of memory,
  and ends with a harmless complaint that it used more memory than declared.
- **The version** of a build is upstream's with build metadata naming the
  fork's commit: `0.17.1+fixes.<short sha>`. It compares equal to upstream's
  release everywhere a version is ordered.
- **Tests** live where upstream keeps them: `test/behavior/` for language
  behavior, `test/cases/` for compile errors, `test/c_abi/`, `test/link/`,
  `test/standalone/`, and `test` blocks beside the code in `lib/std/`.
  - One std test: `zig test lib/std/std.zig --zig-lib-dir lib --test-filter
    <name>`, with the release binary or the built one.
  - A suite: `mise run zig-build -- <step>`. `mise run zig-build -- -l` lists
    the steps, such as `test-behavior`, `test-c-abi` and `test-link`. Plain
    `zig build` fails here on the version check; the task supplies the
    version. `-Dtest-filter=<text>` and `-Dtest-target-filter=<triple>`
    narrow a suite, which is otherwise long.

# Defect backlog

Defects found in Zig that this fork wants fixed, one file per defect. Each
file is the record of context for its fix: what breaks, the evidence, the
responsible code, and what was done about it. The rules for working with this
directory are in [`AGENTS.md`](../AGENTS.md).

## Layout

An entry's directory is its status. Moving the file is how status changes.

| Directory | Meaning |
|---|---|
| `found/` | A defect has been observed or reported. The cause is unknown or only guessed. |
| `root-caused/` | The responsible code is cited as `path:line`, the mechanism is explained, and the defect was reproduced on this line or the faulty code was read there. |
| `fixed/` | The fix is on this line's branch, with a `## Fix` section in the entry. |
| `rejected/` | The cause is known, but no correct, focused fix will be carried here. The entry says why. |

An entry's file name without `.md` is its slug. The slug never changes, so
refer to entries by slug, not by path. Entries that came from upstream's
tracker have a `cb<issue number>-` prefix (Codeberg).

To list entries by field, search the front matter:

```sh
grep -l '^area: linker' defects/*/*.md
grep -L '^affects-line: yes' defects/*/*.md
```

## Front matter

- `priority`: **1** is a defect in everyday toolchain use on a target in the
  matrix below, or a miscompilation or compiler crash on a mainstream target.
  Everyday use means cross-compiling C and C++ with `zig cc`, Zig code that
  binds C libraries, `zig build` with package fetching, and translate-c.
  **2** is a real defect outside that. **3** is confined to exotic targets,
  other self-hosted backends, incremental compilation, or is too vague to act
  on.
- `affects-line`: `yes` means it was reproduced with this line's release
  binary, or the faulty code was read at this line's base. `likely` and
  `unknown` mean nobody checked. `no` means it was checked and is absent.
- `upstream`: issue ids as `codeberg#N` or `github#N`.

New entries start from [`TEMPLATE.md`](TEMPLATE.md).

### Target matrix

The targets this fork cares most about, with the LLVM backend:

- Linux, glibc and musl: x86_64, aarch64, riscv64, loongarch64
- FreeBSD
- macOS, Mac Catalyst, iOS, tvOS, visionOS
- Android: arm, arm64, x86, x86_64
- Windows, MSVC and MinGW: x86_64, aarch64
- OpenHarmony
- Emscripten (wasm32)

## Upstream triage

[`upstream-triage.tsv`](upstream-triage.tsv) holds the decision for every
upstream issue that has been triaged, one row per issue. A sweep triages only
issues that are not in it yet. Decisions: `file` (has an entry here), `list`
(a real defect that did not earn an entry; the reason says why), `skip` (not a
defect), `dup` (covered by the entry in `ref`).

## Provenance

The backlog was first gathered on 2026-11-11 against release tag `0.17.1`.

- 17 entries came from tracing toolchain failures on the target matrix to
  their cause in Zig's source.
- 83 entries came from a sweep of the 940 issues open on upstream's Codeberg
  tracker that day. 312 carried only enhancement, proposal, documentation or
  infrastructure labels and were set aside unread. The other 628 were read and
  triaged: 89 filed (some share an entry), 444 listed, 90 skipped, 5
  duplicates. Only priority 1 issues got an entry. The legacy GitHub tracker
  was not swept.

Root causes and fix sketches from that pass were written by agents and have
not been reviewed. Confirm them before fixing.

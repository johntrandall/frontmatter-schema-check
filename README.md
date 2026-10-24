# frontmatter-schema-check

Checks the frontmatter of markdown notes against a schema kept with each folder, for people and AI agents who use folders of notes as databases.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## In plain terms

Many people keep lists as plain notes: books read, companies to follow, events to attend. Each note starts with a few labelled fields, such as a status or a date. That block at the top of a note is called frontmatter, and apps such as Obsidian turn a folder of these notes into a table. Over time the fields drift: a status gets misspelled, a date goes missing, someone invents a new field. You keep a written set of rules for each folder, and this tool checks every note against them.

- Catches mistakes early: an AI agent working in Claude Code is told about a bad note right after writing it.
- Keeps bad notes out of your saved history: if you track changes with git and install its hook, a change that contains a note breaking the rules is refused.
- Starts from what you have: it drafts the rules for an existing folder from the notes already in it.
- Stays readable: the rules are themselves a markdown note, which a person can read and edit.

## What it does

`frontmatter-schema-check` validates the YAML frontmatter of markdown files. It compares each file with a schema written in JSON Schema 2020-12, the common standard for describing what data may look like. The schemas follow the [mdbase](https://github.com/mdbase-dev/mdbase-spec) layout for typed markdown folders: a one-line `mdbase.yaml` file marks the top folder of a collection, and each kind of note has a type file under `_types/`.

You can run it in three ways:

- As a command, on any files you name.
- As a Claude Code PostToolUse hook. Claude Code runs it after the agent writes a file. The agent sees a warning if the note breaks its rules. The write itself is never undone.
- As a git pre-commit check, which refuses a commit that contains a note breaking its rules.

It can also draft a type file from existing notes. It can check that an Obsidian Base (a `.base` file, Obsidian's saved table view) still loads. And it can count notes by a status field.

## Why it exists

A folder of frontmatter notes works well as a small database until several writers edit it, and AI agents are frequent writers. Nothing in a markdown file enforces the allowed values, so mistakes stay silent until a view looks wrong. JSON Schema already solves validation. This tool attaches a schema to a folder and runs it at the two moments that matter: right after an agent writes a note, and before a commit.

Related tools, and when to choose them:

- [mdvs](https://github.com/edochi/mdvs) infers and validates frontmatter across a whole folder and adds semantic search. Choose it for a general-purpose validator with search. Its schema lives in an `mdvs.toml` file that can be imported from or exported to JSON Schema, and `mdvs check` checks the whole folder.
- [remark-lint-frontmatter-schema](https://github.com/JulianCataldo/remark-lint-frontmatter-schema) checks frontmatter against JSON Schema inside a remark or unified pipeline. Choose it if you already lint markdown with remark.
- [taxidermist](https://github.com/jvanmelckebeke/taxidermist) keeps frontmatter to a declared schema with a pre-commit gate. Choose it for a schema gate that also generates how-to pages.
- [frontmatter-check](https://github.com/kjaymiller/frontmatter-check) checks for required metadata in frontmatter, on its own or as a pre-commit hook. Choose it when you only need to require certain fields.
- This tool fits when you want full JSON Schema stored as readable type files in the mdbase layout, checked one file at a time, with a warning for an agent at write time and a block at commit time.

## Install

```bash
pipx install git+https://github.com/johntrandall/frontmatter-schema-check
```

[pipx](https://pipx.pypa.io/) installs Python command-line tools in their own environments. You need Python 3.10 or newer. The `jsonschema` and `PyYAML` libraries are installed with it. With [uv](https://docs.astral.sh/uv/), `uv tool install git+https://github.com/johntrandall/frontmatter-schema-check` does the same.

## Quick start

The repository ships a sample collection of twenty book notes. Clone it and check the sample:

```bash
git clone https://github.com/johntrandall/frontmatter-schema-check
cd frontmatter-schema-check/tests/fixtures/library
frontmatter-schema-check check books/*.md
```

The command prints nothing and exits 0, because every note follows the rules in `_types/book.md`. Now break one note and check it again:

```bash
perl -pi -e 's/^format: .*/format: scroll/' books/b03.md
frontmatter-schema-check check books/b03.md
```

```text
books/b03.md: format: 'scroll' is not one of ['hardcover', 'paperback', 'ebook']
```

The command exits 1. Restore the note with `git checkout -- books/b03.md`.

To give a folder of notes a schema, mark its top folder and let `init` draft a type file. This example uses a new folder with three notes:

```bash
mkdir -p ~/films-demo/films && cd ~/films-demo
printf -- '---\ntitle: Alien\nrating: great\n---\n' > films/alien.md
printf -- '---\ntitle: Heat\nrating: good\n---\n' > films/heat.md
printf -- '---\ntitle: Ran\nrating: great\n---\n' > films/ran.md
printf 'spec_version: "0.3.0"\n' > mdbase.yaml
frontmatter-schema-check init films
```

```text
wrote _types/films.md: 3 records, 2 fields, 2 required, 1 enum
```

The draft lists each field with the type seen in the notes. A field with a few repeating values becomes a list of allowed values, and dates are marked as dates. When every note has the same `type:` value, the type file is named after that value instead of the folder. Two optional files in the folder improve the draft. A template note whose name starts with `_` and contains `template` can list allowed values in comments, as in `status: open   # open | done`. An Obsidian `.base` file there supplies column names and order. The draft sets `additionalProperties: false`, so a field it did not see in any note is refused. The draft covers only the notes directly in that folder (`<folder>/*.md`); for subfolders, change the glob to `<folder>/**/*.md`. It reads at most 2000 notes. `init` needs an `mdbase.yaml` in the folder or in one of the eight folders above it, which is the same reach `check` has. Without one it refuses and exits 2, because the draft would never apply. Read the draft, correct it, and commit it with the notes.

## How it works

Four rules decide whether a file is checked at all:

1. The file name ends in `.md`, is not `README.md` or `TEMPLATE.md`, and does not start with `_` or `.`. The file is not a symlink: a linked note is checked where its file lives. No folder between the collection root and the file starts with `.` or is named `node_modules`, so a hidden folder inside a collection, such as Obsidian's `.trash`, is never checked. Folders above the root may be hidden: a checkout in `.claude/worktrees/` is checked like any other.
2. An `mdbase.yaml` file exists in the file's folder or in one of the eight folders above it. That folder is the collection root. Only the file's presence matters; its content, by mdbase convention `spec_version: "0.3.0"`, is not read.
3. The root's `_types/` folder, including its subfolders, holds type files: markdown files whose frontmatter has `kind: mdbase.type`. A type file that cannot be read is reported as the type file's fault. These files there are documentation and are skipped: `README.md`, `TEMPLATE.md`, a file with no frontmatter, a file whose frontmatter is a mapping without a `kind: mdbase.type` line (a how-to that quotes a type file below its own frontmatter included), and a file whose opening `---` is never closed and that has no `kind` line. These are reported as broken type files: a file whose frontmatter does not parse or is not a mapping (a list or a plain sentence), a file with a `kind` line whose fence is broken, and a file that cannot be read. A `_contracts/` folder is reserved by the mdbase specification and skipped.
4. A type that has `match.path_glob` matches files by their path only. The glob is relative to the collection root, with no leading `/` or `./`. `*` and `?` stay within one folder. `**` spans folders when it is a whole path segment, such as `notes/**/*.md`. `[abc]` matches one character, and `[!abc]` any other. `{a,b}` alternatives are not supported and are reported as an error; write `[{]` for a literal brace. A note's own `type:` field selects only a type that has no glob. A note that names a type but sits outside that type's glob, and that no glob matches, gets an advisory message saying it is not checked. A `type:` value that names no type file is an ordinary field: it selects nothing and draws no advisory, because many notes use `type:` for their own purposes, and the note is still checked by any type whose glob matches it.

A checked file is validated against each matching type's `schema.value`. The frontmatter is read as YAML 1.2. Aliases (`*name`) are refused in a note's frontmatter; an anchor (`&name`) on its own is allowed. A key written twice is an error. A merge key (`<<`) in a type file is reported, since YAML 1.2 has none. In that version, `20:00`, `off` and `yes` stay text instead of becoming numbers or true and false. Unlike the YAML 1.2 core schema, which reads `01234` as the number 1234, this tool keeps a number written with a leading zero as text. A key written as a number, such as `1:`, is checked as the text `"1"`, as in JSON. A pass prints nothing. On a disk that ignores letter case, as macOS does by default, a folder below the collection root given in the wrong case does not match the type's `path_glob`, so the note is not checked and the command exits 0; if the note's `type:` field names that type, an advisory says it was not checked. Give paths in the case the folders really have. The commit check uses git's spelling and is not affected. A failure lists wrong values first and puts each note's missing fields on one line. Note paths in the output are relative to the collection root, and the hook also names the type file by its full path, with your home folder shown as `~`. The hook shows at most five lines and `check` shows up to fifty; a final line `... N more` counts the rest. `--max-lines` changes the limit for both. `base-check` always shows up to fifty.

### Commands

```text
frontmatter-schema-check check <file>...             validate notes; exit 1 on any problem, including a missing file
frontmatter-schema-check check --staged              validate what is staged for the next git commit
frontmatter-schema-check hook                        Claude Code PostToolUse hook: reads the hook's JSON on standard input,
                                                     always exits 0, warns in additionalContext
frontmatter-schema-check init <folder> [--out FILE]  draft _types/<name>.md from a folder's notes; never overwrites
frontmatter-schema-check base-check <file.base>...   check that Obsidian Bases load
frontmatter-schema-check count <folder>              count notes by a status field (see below)
frontmatter-schema-check install-git-hook <repo>     add `check --staged` to a repository's pre-commit hook
options: --json   --max-lines N   --engine auto|python|mdbase (default auto, the built-in Python engine)   -h, --help
         --version (as the first argument)
exit codes: 0 no problems   1 problems found   2 cannot run (a missing library, a folder given to check, check --staged
            outside git, init or count on a folder outside any collection or that cannot be read, init on a folder with no notes that have frontmatter, init or count given something that is not a folder, count with a values entry that is not a list, init refusing to overwrite, install-git-hook refusing)
            64 bad arguments (an unknown command or option, a missing or bad option value, the wrong number of
            arguments)
```

Given a type file, `check` reports any problem with the type file itself and checks every note in that type file's collection.

### Claude Code hook

Add this entry to the `PostToolUse` list in `~/.claude/settings.json`. If the file already has a `hooks` section, merge the entry into it rather than replacing it:

```json
{ "hooks": { "PostToolUse": [ { "matcher": "Edit|Write|MultiEdit",
  "hooks": [ { "type": "command", "command": "frontmatter-schema-check hook", "timeout": 30 } ] } ] } }
```

The hook never blocks a write. When an agent writes an Obsidian Base that does not load, the hook says so. When an agent writes a type file that does not load, the hook says so, because a broken type file stops its whole collection being checked. When an agent writes a Base that loads cleanly into a vault folder of notes that no type file covers, the hook asks it to create one with `init` (and to add an `mdbase.yaml` first when the folder is in no collection). Claude Code shows the warning next to the result of the tool call, so the agent can fix the field at once. The hook only sees files that the agent writes with its Write, Edit and MultiEdit tools. Changes made with shell commands are caught at commit time.

Each warning about a note is also appended as one line to `~/.local/state/frontmatter-schema-check/hook-failures.jsonl`. Warnings about a type file the agent wrote, and about Obsidian Bases, are not logged. The line holds the time, the file path, the tool name, the Claude Code session identifier, the working folder, the problem count, the problem codes and the first problem. Set `FRONTMATTER_SCHEMA_CHECK_STATE` to use another folder.

### Pre-commit check

`check --staged` validates the content that is staged for the commit, not the file on disk. Three details matter:

- Everything is read as the commit holds it, from git's index: the notes, the type files and the `mdbase.yaml` markers. A type file, a folder inside `_types`, or `_types` itself that is a symlink is reported as an error, because its content can change outside the commit; commit the files themselves. A symlink to a documentation file there is ignored. A symlinked `mdbase.yaml` counts, since only its presence matters. Adding, changing or deleting a marker or a type file re-checks every note its collection now holds. An unstaged edit to a type file, or a file deleted on disk but not in the index, does not change the result. A type file or marker that git does not track is not part of the commit and does not apply, so add a new collection's `mdbase.yaml` and type files in the same commit as its notes.
- When a type file itself is staged, every note in its collection is checked against the staged type files. Each note is read as it will be committed, from git's index, and notes that git does not track are skipped.
- For a staged `.base` file, the structure check uses the staged content. The Obsidian engine check runs only when the staged content matches the file on disk.

`install-git-hook` adds the check near the top of a shell pre-commit hook. It also adds it to the pre-merge-commit hook, so merge commits are checked too. It honours `core.hooksPath`, git's setting for a custom hooks folder. It checks both hooks before writing either. It refuses, and changes nothing, when the folder is not a git work tree, when the hooks folder cannot be created or belongs to husky, or in any of four cases for either hook: the existing hook is a symlink, it is not a shell script, it cannot be read and written (or is a folder), or it is managed by lefthook. An empty existing hook is replaced with a fresh one. If an existing hook is not executable, the line is added but git still does not run that hook; the command says so.

With lefthook, add `frontmatter-schema-check check --staged` to your lefthook configuration instead. For a symlinked or non-shell hook, call `frontmatter-schema-check check --staged` from that hook yourself and exit non-zero when it fails. A refusal exits 2.

Running `install-git-hook` again replaces a check line written by an earlier version; it recognises its own lines by their trailing `# frontmatter-schema-check` comment (or `# record-schema`, the tool's working name before release) and leaves lines you wrote alone. The installed line looks for the command on PATH first. If it is not there, it runs the module with the same Python interpreter that installed it, at the absolute paths recorded when it was installed. If it finds neither, the check is skipped, so that git clients with a short PATH do not block every commit. If the check runs but cannot work, for example because a library is missing, the command exits 2 and the commit is refused.

Git runs no pre-commit hook for `git rebase` (including `--continue`), `git am`, a cherry-pick or revert that applies without a conflict, a fast-forward merge or pull, or `git commit --no-verify`, so commits made that way are not checked. A cherry-pick or revert that stops on a conflict is checked when you finish it with `--continue`. Run `frontmatter-schema-check check` on the collection afterwards if you use them.

### Obsidian Bases

A `.base` file is treated as an Obsidian Base only inside an Obsidian vault, and only when it looks like one. Other files with that suffix, such as `Dockerfile.base`, are ignored, and `base-check` reports them as skipped. The check runs in two steps. First, a structure check runs without Obsidian: the file must be valid YAML without aliases, every `and`, `or` and `not` filter must be a list, and every view needs a name. Second, Obsidian's own engine queries the Base through the `obsidian` command-line tool, or through the macOS app when that tool is not on PATH. That step needs Obsidian running with the vault open, and the vault must be one Obsidian knows about. When it cannot reach Obsidian, `check` and `base-check` report the Base as failing, so `check --staged` refuses the commit and tells you to open the vault. A vault Obsidian has never opened gets the structure check only. When no Obsidian tool is installed at all, as on most Linux machines, the engine step is skipped and only the structure check decides. Set `FRONTMATTER_SCHEMA_CHECK_OBSIDIAN` to the path of the Obsidian command-line tool, or to `none` to skip the engine step.

Obsidian's engine does not report broken formulas, unknown view types or unknown filter functions, so neither does this tool. It also notes, without failing, any view whose column order does not put `file.name` first or second. `file.name` is the column that opens the note when clicked.

### Counting

A type file can name a status field and the values that mean "waiting for a person". Add a top-level block to its frontmatter:

```yaml
x-record-schema:
  awaiting_human: { field: status, values: [waiting] }
```

The type file must use `match.path_glob`, and `values` must be a list. `count <folder>` then reports the total and the number of notes waiting, reading only that folder. `--json` gives `folder`, `field`, `awaiting_values`, `total`, `awaiting`, `by_value` and `unparsable`. In `by_value`, a field that is absent appears as `(missing)` and a null value as `null`. A text value that YAML would read as something else, such as `"3"` or `"null"`, is shown in quotes, so it stays apart from the number or the null.

### Engines

The default engine is built in and uses the Python `jsonschema` library. `--engine mdbase` uses the mdbase command-line tool instead, if it is installed. That tool may select types and read some YAML differently, so its results can differ. `check --staged` always uses the built-in engine.

## Status / Roadmap

Experimental. The first release was in October 2026, and the author uses it on his own agent-maintained collections. The commands and the type-file layout are not expected to change. The wording of messages may change.

- Ask mdbase and mdvs whether they can check one file at a time, so either could serve as the engine for a write hook.
- Add a Homebrew formula.

## Contributing

Report problems in [GitHub issues](https://github.com/johntrandall/frontmatter-schema-check/issues). Include the note, the type file and the command's output. A failing case added to `tests/run.sh` is the most useful kind of report.

Pull requests are welcome. Run `bash tests/run.sh` before you send one, inside a virtual environment where you ran `pip install -e .`. The tests need Python 3.10 or newer, bash, git, jq and perl. They never call Obsidian. They also run the mdbase engine when the `mdbase` tool is on PATH.

## License

[MIT](LICENSE)

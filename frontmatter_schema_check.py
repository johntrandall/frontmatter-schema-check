#!/usr/bin/env python3
"""frontmatter-schema-check: validate markdown frontmatter against the type file of its collection.

A collection is a folder tree marked by `mdbase.yaml`; each kind of note has a type file in `_types/` whose
frontmatter holds `kind: mdbase.type`, `name`, `match.path_glob` and a JSON Schema 2020-12 under `schema.value`.
Full documentation: https://github.com/johntrandall/frontmatter-schema-check#readme

  frontmatter-schema-check check <file>...             validate notes; exit 1 on any problem
  frontmatter-schema-check check --staged              validate what is staged for the next git commit
  frontmatter-schema-check hook                        Claude Code PostToolUse hook; always exits 0, warns in additionalContext
  frontmatter-schema-check init <folder> [--out FILE]  draft a type file from a folder's notes; never overwrites
  frontmatter-schema-check base-check <file.base>...   check that Obsidian Bases load
  frontmatter-schema-check count <folder>              count notes by the field named in an x-record-schema.awaiting_human block
  frontmatter-schema-check install-git-hook <repo>     add `check --staged` to a repository's shell pre-commit hook
  options: --json   --max-lines N (hook default 5, check default 50)   --engine python|mdbase
"""
import sys, os, re, json, subprocess, shutil, datetime, shlex

MARKER = "mdbase.yaml"
TYPES_DIR = "_types"
MAX_UP = 8


def tilde(path):
    """Shorten the home folder to ~ only as a whole path prefix."""
    home = os.path.expanduser("~").rstrip(os.sep)
    if isinstance(path, str) and (path == home or path.startswith(home + os.sep)):
        return "~" + path[len(home):]
    return path


# ---------- rule 1: is this even a candidate ----------
def is_candidate(path, root=None):
    """A note file name, not inside a hidden folder below its collection root. Folders above the root may be hidden:
    a checkout in .claude/worktrees/ is a collection like any other."""
    base = os.path.basename(path)
    if not base.endswith(".md") or base in ("README.md", "TEMPLATE.md") or base.startswith("_"):
        return False
    if os.path.islink(path) and not STAGED:
        return False   # a symlinked note is checked where its file lives, not through the link (the index skips links too)
    root = root or find_root(path)
    below = os.path.relpath(os.path.abspath(path), root) if root else os.path.abspath(path)
    return not any(part.startswith(".") or part == "node_modules" for part in below.split(os.sep) if part and part != "..")


# ---------- rule 2: collection root ----------
STAGED_MARKERS = None   # under --staged: folders whose mdbase.yaml is in git's index (the commit's collections)


def find_root(path):
    d = os.path.dirname(os.path.abspath(path))
    for _ in range(MAX_UP + 1):
        if (os.path.realpath(d) in STAGED_MARKERS) if STAGED_MARKERS is not None else os.path.isfile(os.path.join(d, MARKER)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


# ---------- YAML 1.2 core schema (what mdbase reads; PyYAML defaults to 1.1) ----------
_CORE = None


def core_loader():
    global _CORE
    if _CORE is not None:
        return _CORE
    import yaml

    class CoreLoader(yaml.SafeLoader):
        pass
    def construct_mapping(self, node, deep=False):
        # YAML 1.2 forbids duplicate keys; keys become what JSON sees (`1:` and `true:` are "1" and "true", not 1 == True)
        if not isinstance(node, yaml.MappingNode):
            raise yaml.constructor.ConstructorError(None, None, f"expected a mapping, found {node.id}", node.start_mark)
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=True)
            key = json_key(key) if not isinstance(key, (list, dict)) else json.dumps(iso_dates(key), sort_keys=True)
            if key in mapping:
                raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", key_node.start_mark)
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping
    CoreLoader.construct_mapping = construct_mapping
    CoreLoader.yaml_implicit_resolvers = {}
    CoreLoader.add_implicit_resolver("tag:yaml.org,2002:null", re.compile(r"^(?:~|null|Null|NULL|)$"), list("~nN") + [None])
    CoreLoader.add_implicit_resolver("tag:yaml.org,2002:bool", re.compile(r"^(?:true|True|TRUE|false|False|FALSE)$"), list("tTfF"))
    CoreLoader.add_implicit_resolver("tag:yaml.org,2002:int", re.compile(r"^(?:[-+]?(?:0|[1-9][0-9]*)|0o[0-7]+|0x[0-9a-fA-F]+)$"), list("-+0123456789"))
    CoreLoader.add_implicit_resolver("tag:yaml.org,2002:float",
        re.compile(r"^(?:[-+]?(?:\.[0-9]+|(?:0|[1-9][0-9]*)(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"), list("-+0123456789."))
    _CORE = CoreLoader
    return _CORE


_NOALIAS = None


_NOALIAS_SAFE = None


def no_alias_safe_loader():
    """PyYAML's SafeLoader without aliases, for Obsidian .base files (Obsidian writes none)."""
    global _NOALIAS_SAFE
    if _NOALIAS_SAFE is None:
        import yaml

        class NoAliasSafe(yaml.SafeLoader):
            def construct_mapping(self, node, deep=False):
                keys = [self.construct_object(k, deep=True) for k, _ in node.value] if isinstance(node, yaml.MappingNode) else []
                dup = next((k for i, k in enumerate(keys) if isinstance(k, (str, int, float, bool)) and k in keys[:i]), None)
                if dup is not None:
                    raise yaml.constructor.ConstructorError(None, None, f"duplicate key {dup!r}", node.start_mark)
                return super().construct_mapping(node, deep)

            def compose_node(self, parent, index):
                if self.check_event(yaml.AliasEvent):
                    raise yaml.YAMLError("YAML aliases (*name) are not allowed in a .base file")
                return super().compose_node(parent, index)
        _NOALIAS_SAFE = NoAliasSafe
    return _NOALIAS_SAFE


def too_big(obj, limit=200000):
    """True when a parsed value has more than `limit` nodes once aliases are followed (an alias bomb in a type file)."""
    n, stack = 0, [obj]
    while stack:
        n += 1
        if n > limit:
            return True
        x = stack.pop()
        if isinstance(x, dict):
            stack.extend(x.keys()); stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
    return False


def no_alias_loader():
    """The core loader, refusing YAML aliases: a note's frontmatter never needs them, and a few hundred bytes of
    nested aliases can expand to gigabytes. Type files are read with aliases allowed."""
    global _NOALIAS
    if _NOALIAS is None:
        import yaml

        class NoAlias(core_loader()):
            def compose_node(self, parent, index):
                if self.check_event(yaml.AliasEvent):
                    raise yaml.YAMLError("YAML aliases (*name) are not allowed in a note's frontmatter")
                return super().compose_node(parent, index)
        _NOALIAS = NoAlias
    return _NOALIAS


# ---------- frontmatter ----------
def frontmatter(text, allow_aliases=False):
    if text.startswith("\ufeff"):
        text = text[1:]   # a byte order mark before the opening --- is not content
    m = re.match(r"^---\r?\n(?:(.*?)\r?\n)?---(?:\r?\n|$)", text, re.S)
    if not m:
        return None, "no frontmatter"
    import yaml
    loader = core_loader() if allow_aliases else no_alias_loader()
    try:
        fm = yaml.load(m.group(1) or "", Loader=loader)
    except yaml.YAMLError as e:
        return None, f"yaml: {str(e).splitlines()[0]}"
    except RecursionError:
        return None, "yaml: nested too deeply"
    except Exception as e:  # any other parser failure is a problem with the file, never a crash
        return None, f"yaml: {type(e).__name__}: {str(e)[:120]}"
    if fm is None:
        fm = {}
    if not isinstance(fm, dict):
        return None, "frontmatter is not a mapping"
    return fm, None


def json_key(k):
    """A mapping key as JSON sees it: JSON Schema property names are strings."""
    if isinstance(k, str):
        return k
    if k is None or isinstance(k, bool):
        return json.dumps(k)
    return iso_dates(k) if isinstance(k, (datetime.date, datetime.datetime)) else str(k)


def iso_dates(obj):
    if isinstance(obj, datetime.datetime):
        return obj.isoformat()
    if isinstance(obj, datetime.date):
        return obj.isoformat()
    if isinstance(obj, dict):
        return {json_key(k): iso_dates(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [iso_dates(v) for v in obj]
    return obj


# ---------- rule 3: type files ----------

STAGED = False      # set by `check --staged`: type files and notes are read from git's index, the commit's content
_TYPES_CACHE = {}


def looks_like_type_file(text):
    """True when text is meant as a type file: it opens with a --- fence (even a broken one) and says kind: mdbase.type
    in that opening block. A how-to that quotes a type file further down is documentation."""
    if not isinstance(text, str):
        return False
    head = text.lstrip("\ufeff")
    if not head.startswith("---"):
        return False
    block = head.split("\n---", 1)[0] if "\n---" in head[3:] else "\n".join(head.splitlines()[:60])
    return re.search(r"^kind:[ \t]*['\"]?mdbase\.type", block, re.M) is not None


def links_to_type_file(path):
    try:
        return looks_like_type_file(open(path, encoding="utf-8", errors="replace").read(20000))
    except OSError:
        return True   # cannot tell: treat as a type file, so the commit is refused rather than passed


def type_file_texts(root):
    """[(path, text or OSError)] for the type files of a collection: from git's index under --staged, else from disk."""
    out = []
    indexed = {}
    if STAGED:
        # Type files exactly as the commit holds them, in git's index; one that git does not track is not in the commit.
        root = os.path.realpath(root)
        for mode, sha, p in index_entries(root, TYPES_DIR, symlinks=True):
            parts = os.path.relpath(p, os.path.join(root, TYPES_DIR)).split(os.sep)
            folder_link = os.path.normpath(p) == os.path.normpath(os.path.join(root, TYPES_DIR))
            inside = not any(x.startswith(".") or x == "_contracts" for x in parts[:-1]) and parts[-1] not in ("README.md", "TEMPLATE.md")
            if mode == b"120000" and (folder_link or (inside and (os.path.isdir(p) or (p.endswith(".md") and links_to_type_file(p))))):
                # A link's content lives elsewhere and can change without this commit; refuse rather than guess.
                out.append((p, OSError(f"{os.path.relpath(p, root)} is a symlink; commit the type file itself (a symlinked type file "
                                        "or _types folder is not checked reliably at commit time)")))
        for p, text in sorted(index_contents(root, TYPES_DIR).items(), key=lambda kv: kv[0]):
            parts = os.path.relpath(p, os.path.join(root, TYPES_DIR)).split(os.sep)
            if any(x.startswith(".") or x == "_contracts" for x in parts[:-1]) or parts[-1] in ("README.md", "TEMPLATE.md"):
                continue
            out.append((p, text))
        return out
    tdir = os.path.join(root, TYPES_DIR)
    if os.path.islink(tdir):
        return [(tdir, OSError(f"{TYPES_DIR} is a symlink; keep the type files in the collection (a link's content can change outside the commit)"))]
    if os.path.isdir(tdir) and not os.access(tdir, os.R_OK | os.X_OK):
        out.append((tdir, OSError(f"{TYPES_DIR}/ cannot be read, so no type file in it applies")))
    walk_errors = []
    for dirpath, dirnames, files in os.walk(tdir, onerror=walk_errors.append):
        for d in dirnames:
            if os.path.islink(os.path.join(dirpath, d)) and not d.startswith(".") and d != "_contracts":
                out.append((os.path.join(dirpath, d), OSError(f"{os.path.relpath(os.path.join(dirpath, d), root)} is a symlinked folder; "
                                                               "copy its type files into _types (a link's content can change outside the commit)")))
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "_contracts")
        for f in sorted(files):
            if not f.endswith(".md") or f in ("README.md", "TEMPLATE.md"):
                continue
            p = os.path.join(dirpath, f)
            if os.path.islink(p):
                if links_to_type_file(p):
                    out.append((p, OSError(f"{os.path.relpath(p, root)} is a symlink; copy the type file itself into {TYPES_DIR}")))
                continue   # a link to documentation is ignored
            try:
                out.append((p, open(p, encoding="utf-8", errors="replace").read()))
            except OSError as e:
                out.append((p, e))
    for e in walk_errors:
        if e.filename and os.path.realpath(e.filename) != os.path.realpath(tdir):
            out.append((e.filename, OSError(f"{os.path.relpath(e.filename, root)}/ cannot be read, so no type file in it applies")))
    return out


def load_types(root):
    """Return (types, diagnostics), cached per collection for the run. A type file that does not parse is itself a diagnostic."""
    key = (os.path.realpath(root), STAGED)
    if key not in _TYPES_CACHE:
        _TYPES_CACHE[key] = _load_types(root)
    return _TYPES_CACHE[key]


def _load_types(root):
    types, diags = [], []
    for p, text in type_file_texts(root):
            # real folders on both sides (/var vs /private/var), but not through the file itself: it may be a link
            rel = os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p)), os.path.realpath(root))
            if isinstance(text, OSError):
                fm, err = None, str(text)
            else:
                fm, err = frontmatter(text, allow_aliases=True)
            if err == "no frontmatter":
                if looks_like_type_file(text):
                    # meant as a type file, but its fence is broken: say so rather than skip it as documentation
                    diags.append(diag("type_file_unreadable", "", "frontmatter not found: a type file opens with a line of exactly ---", rel, None))
                continue
            if err:
                diags.append(diag("type_file_unreadable", "", err, rel, None)); continue
            if fm.get("kind") != "mdbase.type":
                continue
            if too_big(fm):
                diags.append(diag("type_file_invalid", "", "type file expands to too many nodes (YAML aliases)", rel, None)); continue
            match, sch = fm.get("match"), fm.get("schema")
            if match is not None and not isinstance(match, dict):
                diags.append(diag("type_file_invalid", "match", "match must be a mapping with path_glob", rel, None)); continue
            if not isinstance(sch, dict):
                diags.append(diag("type_file_invalid", "schema", "schema must be a mapping with value", rel, None)); continue
            name = fm.get("name"); glob = (match or {}).get("path_glob")
            if glob is not None and not isinstance(glob, str):
                diags.append(diag("type_file_invalid", "match.path_glob", "path_glob must be one string", rel, None)); continue
            schema = sch.get("value")
            if contains_key(fm, "<<"):
                diags.append(diag("type_file_invalid", "", "YAML merge keys (<<) are not part of YAML 1.2; repeat the fields or use an anchor for a whole value", rel, None)); continue
            if isinstance(glob, str) and (glob.startswith(("/", "./")) or "{" in re.sub(r"\[[^\]]*\]", "", glob)):
                diags.append(diag("type_file_invalid", "match.path_glob", f"path_glob {glob!r}: write it relative to the collection root, without a leading / or ./, and without {{a,b}} alternatives", rel, None)); continue
            if isinstance(glob, str):
                try:
                    glob_to_regex(glob)
                except re.error as e:
                    diags.append(diag("type_file_invalid", "match.path_glob", f"bad glob {glob!r}: {e}", rel, None)); continue
            if not isinstance(name, str) or not name:
                diags.append(diag("type_file_invalid", "name", "type file has no name", rel, None)); continue
            if not isinstance(schema, dict):
                diags.append(diag("type_file_invalid", "schema.value", "type file has no schema.value object", rel, None)); continue
            try:
                from jsonschema import Draft202012Validator
                Draft202012Validator.check_schema(schema)   # a typo such as `type: strng` makes the whole type file unusable
            except Exception as e:
                diags.append(diag("type_file_invalid", "schema.value", f"schema does not compile: {str(e).splitlines()[0][:200]}", rel, name)); continue
            types.append({"name": name, "glob": glob if isinstance(glob, str) else None, "schema": schema, "path": rel})
    return types, diags


def contains_key(obj, key):
    stack = [obj]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            if key in x:
                return True
            stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
    return False


def nfc(text):
    import unicodedata
    return unicodedata.normalize("NFC", text)


def glob_to_regex(glob):
    """mdbase path globs: * and ? never cross '/', ** as a whole component spans components. Unicode is compared in
    composed form (NFC): macOS file names and git paths may spell the same é differently."""
    import unicodedata
    glob = unicodedata.normalize("NFC", glob)
    parts = glob.split("/")
    out = []
    for i, part in enumerate(parts):
        if part == "**":
            out.append("(?:[^/]+/)*" if i < len(parts) - 1 else "(?:[^/]+(?:/[^/]+)*)?")
            continue
        seg = ""
        j = 0
        while j < len(part):
            c = part[j]
            if c == "*": seg += "[^/]*"
            elif c == "?": seg += "[^/]"
            elif c == "[":
                k = part.find("]", j + 1)
                if k == -1: seg += re.escape(c)
                else:
                    body = part[j + 1:k]
                    if body.startswith("!"): body = "^" + body[1:]
                    seg += "[" + body + "]"; j = k
            else: seg += re.escape(c)
            j += 1
        out.append(seg + ("/" if i < len(parts) - 1 else ""))
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return re.compile("^" + "".join(out) + "$")


# ---------- rule 4: match ----------
def matched_types(types, rel, fm):
    """Glob wins: a type that declares match.path_glob matches by path only. A record's explicit `type:` key
    selects only a type that declares no glob. (Otherwise archive records carrying `type: event` and templates carrying `type: intake` are pulled into types
    meant for one folder.)"""
    explicit = fm.get("type") if isinstance(fm, dict) else None
    out = []
    for t in types:
        if t["glob"]:
            if glob_to_regex(t["glob"]).match(nfc(rel)):
                out.append(t)
        elif isinstance(explicit, str) and explicit.lower() == t["name"].lower():
            out.append(t)
    return out


def orphan_type_note(types, rel, fm):
    """A record that names a type in its frontmatter but sits outside that type's glob is NOT validated (glob wins).
    Say so, never block: otherwise such records go unchecked without anyone noticing."""
    explicit = fm.get("type") if isinstance(fm, dict) else None
    if not isinstance(explicit, str):
        return None
    for t in types:
        if t["name"].lower() == explicit.lower() and t["glob"] and not glob_to_regex(t["glob"]).match(nfc(rel)):
            return (f"{rel}: declares type: {explicit}, but {t['path']} only matches path_glob {t['glob']!r}, so this record "
                    f"is NOT checked. Move it under that glob, or add a type file whose glob covers this folder.")
    # A type: value that names no type file is an ordinary field (notes use type: for their own purposes; on 2026-10-24
    # 129 live notes did), so it stays silent rather than nag every write.
    return None


# ---------- rule 5: engines ----------
def diag(code, field, message, path, type_name):
    return {"code": code, "field": field, "message": message, "path": path, "type": type_name}


def message_field(e):
    """The property a required or additionalProperties error is about, read exactly (names may hold quotes)."""
    import ast
    try:
        if e.validator == "required":
            return str(ast.literal_eval(e.message.rsplit(" is a required property", 1)[0]))
        inner = e.message[e.message.index("(") + 1:e.message.rindex(" was" if " was unexpected" in e.message else " were")]
        first = ast.literal_eval("(" + inner + ",)")[0]
        return str(first)
    except Exception:
        m = re.search(r"'([^']+)'", e.message); return m.group(1) if m else ""


def engine_python(root, rel, fm, types):
    import jsonschema
    from jsonschema import Draft202012Validator, FormatChecker
    out = []
    data = iso_dates(fm)
    for t in types:
        try:
            Draft202012Validator.check_schema(t["schema"])
            v = Draft202012Validator(t["schema"], format_checker=FormatChecker())
            errors = sorted(v.iter_errors(data), key=lambda e: [str(x) for x in e.absolute_path])
        except Exception as e:
            msg = str(e).splitlines()[0][:200]
            out.append(diag("type_file_invalid", "schema.value", f"schema does not compile: {msg}", t["path"], t["name"])); continue
        for e in errors:
            field = "/".join(str(p) for p in e.absolute_path)
            if e.validator in ("required", "additionalProperties") and (not field or e.validator == "required"):
                field = "/".join(x for x in (field, message_field(e)) if x)   # a nested miss names meta/isbn, not meta
            out.append(diag("schema_" + str(e.validator).lower().replace("additionalproperties", "additional_properties"),
                            field, e.message.replace("\n", " ")[:200], rel, t["name"]))
    return out


def engine_mdbase(root, rel):
    r = subprocess.run(["mdbase", "-C", root, "--json", "validate", rel], capture_output=True, text=True, timeout=30)
    j = None
    for stream in (r.stdout, r.stderr):
        try:
            j = json.loads(stream); break
        except ValueError:
            continue
    if j is None:
        raise RuntimeError(f"mdbase gave no JSON (exit {r.returncode}): {(r.stderr or r.stdout)[:200]}")
    out = [diag(d.get("code", "schema"), d.get("field", ""), d.get("message", ""), d.get("path", rel), d.get("type")) for d in j.get("diagnostics", [])]
    if not out and (j.get("error") or j.get("valid") is False):
        err = j.get("error") or {}
        msg = err.get("message") if isinstance(err, dict) else str(err)
        out = [diag("mdbase_error", "", f"mdbase could not validate: {msg or 'valid: false with no diagnostics'}", rel, None)]
    return out


def check_file(path, engine="auto", text=None):
    """Return (diagnostics, info). Empty diagnostics = pass (including every 'not a record' exit).
    text: validate this content instead of the file on disk (pre-commit passes the staged blob)."""
    if not is_candidate(path):
        return [], "skip:not-candidate"
    root = find_root(path)
    if root is None:
        return [], "skip:no-collection"
    rel = os.path.relpath(os.path.abspath(path), root).replace(os.sep, "/")
    if rel.split("/")[0] in (TYPES_DIR, "_contracts") or rel == MARKER:   # _contracts/ is reserved by the mdbase spec
        return [], "skip:reserved"
    types, diags = load_types(root)
    if diags:
        return diags, "type-files-broken"
    from_index = text is not None
    if text is None:
        if not os.path.isfile(path):
            return [], "skip:deleted"
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            return [diag("record_unreadable", "", str(e)[:200], rel, None)], "unreadable"
    fm, err = frontmatter(text)
    if err:
        m = re.search(r"^type:[ \t]*[\"']?([A-Za-z0-9][A-Za-z0-9._-]*)", text or "", re.M)   # the note's own type, read loosely
        ts = matched_types(types, rel, {"type": m.group(1)} if m else {})
        return ([diag("frontmatter_unparsable", "", err, rel, ts[0]["name"] if ts else None)] if ts else []), "unparsable"
    ts = matched_types(types, rel, fm)
    if not ts:
        note = orphan_type_note(types, rel, fm)
        return [], ("note:" + note) if note else "skip:untyped"
    # auto = python. The mdbase binary selects types by a record's own `type:` and reads YAML slightly differently,
    # so it is used only when asked for explicitly, and never on staged content.
    use = "python" if engine == "auto" or from_index else engine
    if use == "mdbase" and not shutil.which("mdbase"):
        sys.stderr.write("frontmatter-schema-check: --engine mdbase but no mdbase on PATH; using python\n"); use = "python"
    if use == "mdbase":
        try:
            return engine_mdbase(root, rel), "mdbase"
        except Exception as e:
            sys.stderr.write(f"frontmatter-schema-check: mdbase engine failed ({e}); using python\n")
    return engine_python(root, rel, fm, ts), "python"


def cannot_run(message):
    """The command could not do its job (not a problem in the notes): message on stderr, exit 2."""
    sys.stderr.write(message + "\n"); sys.exit(2)


EMPTY_BLOB = b"e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"


_GIT_TOP = None


def git_top():
    """The work-tree top, found once from the process's own folder. Every git call runs from here with paths relative
    to it: inside a hook git exports GIT_DIR, and then `git -C <subfolder>` would take the subfolder for the top."""
    global _GIT_TOP
    if _GIT_TOP is None:
        _GIT_TOP = os.path.realpath(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or ".")
    return _GIT_TOP


def index_entries(cwd, pathspec=".", symlinks=False):
    """[(mode, sha, path)] for files in the git index under cwd/pathspec, path joined to the work-tree top.
    Submodules (160000) are left out; symlinks (120000) too unless asked for, since a link's blob is its target's name."""
    top = git_top()
    spec = os.path.relpath(os.path.join(os.path.realpath(cwd), pathspec), top)
    if spec.startswith(".."):
        return []   # outside this repository
    r = subprocess.run(["git", "--literal-pathspecs", "-C", top, "ls-files", "-z", "--stage", "--", spec], capture_output=True)
    out = []
    for entry in [x for x in r.stdout.split(b"\0") if x]:
        meta, _, rel = entry.partition(b"\t")
        mode, sha = meta.split(b" ")[0], meta.split(b" ")[1]
        if mode == b"160000" or (mode == b"120000" and not symlinks):
            continue
        out.append((mode, sha, os.path.join(top, rel.decode("utf-8", errors="surrogateescape"))))
    return out


_ITA = None


def intent_to_add(sha, path):
    """`git add -N` entries (git status marks them ".A"): the commit does not contain them. A real empty file is not one."""
    global _ITA
    if _ITA is None:
        out = subprocess.run(["git", "-C", git_top(), "status", "--porcelain=v2", "-z", "--untracked-files=no"], capture_output=True).stdout
        _ITA = {os.path.join(git_top(), e.split(b" ", 8)[8].decode("utf-8", errors="surrogateescape"))
                for e in out.split(b"\0") if e.startswith(b"1 .A ") and len(e.split(b" ", 8)) == 9}
    return path in _ITA


def index_notes(root):
    """{path: content in the git index} for every tracked note under root: what the commit will contain, including
    notes deleted on disk but not staged as deleted. Paths come from git (composed Unicode), not from the disk."""
    return index_contents(root, ".")


def cat_blobs(shas):
    """Contents of several blobs from one `git cat-file --batch`, in order."""
    if not shas:
        return []
    out = subprocess.run(["git", "-C", git_top(), "cat-file", "--batch"], input=b"\n".join(shas) + b"\n", capture_output=True).stdout
    blobs, i = [], 0
    for _ in shas:
        header_end = out.index(b"\n", i); fields = out[i:header_end].split(b" ")
        if len(fields) < 3:   # "<sha> missing"
            blobs.append(None); i = header_end + 1; continue
        size = int(fields[2]); blobs.append(out[header_end + 1:header_end + 1 + size]); i = header_end + 2 + size
    return blobs


def link_target(path, sha):
    """Where a tracked symlink points, from its blob (the commit's link, not the disk's)."""
    target = (cat_blobs([sha])[0] or b"").decode("utf-8", errors="surrogateescape")
    return os.path.normpath(os.path.join(os.path.dirname(path), target))


def indexed_link_target(path, sha):
    """The content a tracked symlink names, as the commit holds it: the target's indexed blob when the target is in this
    repository, the file on disk only when the link leaves the repository."""
    target = link_target(path, sha)
    if os.path.relpath(os.path.realpath(os.path.dirname(target)), git_top()).startswith(".."):
        try:
            return open(target, encoding="utf-8", errors="replace").read()
        except OSError as e:
            return e
    entry = [(m, h) for m, h, q in index_entries(os.path.dirname(target), os.path.basename(target), symlinks=True)]
    if not entry or entry[0][0] == b"120000":
        return OSError(f"{os.path.relpath(path, git_top())} links to {os.path.relpath(target, git_top())}, which is not in the commit")
    blob = cat_blobs([entry[0][1]])[0]
    return blob.decode("utf-8", errors="replace") if blob is not None else OSError("link target unreadable")


def index_contents(root, pathspec, follow_symlinks=False):
    """{path: indexed content} for the tracked .md files under root/pathspec. follow_symlinks: a tracked symlink (a
    shared type file) is read through its link, since the commit holds the link and the link names that file."""
    linked = {}
    if follow_symlinks:
        for mode, sha, p in index_entries(root, pathspec, symlinks=True):
            if mode == b"120000" and p.endswith(".md"):
                linked[p] = indexed_link_target(p, sha)
    entries = [(sha, p) for mode, sha, p in index_entries(root, pathspec) if p.endswith(".md") and not intent_to_add(sha, p)]
    contents = {p: (b.decode("utf-8", errors="replace") if b is not None else OSError("blob missing from the repository"))
                for (_, p), b in zip(entries, cat_blobs([sha for sha, _ in entries]))}
    contents.update(linked)
    return contents


def unusable_type_file(path, root):
    """A diagnostic when a file under _types/ that someone named or wrote is not a type file that loads, else None.
    (Files there without kind: mdbase.type are documentation to the collection, but naming one means it was meant.)"""
    if os.path.basename(path) in ("README.md", "TEMPLATE.md") or not path.endswith(".md"):
        return None
    rel = os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path)), os.path.realpath(root))
    if any(x == "_contracts" or x.startswith(".") for x in rel.split(os.sep)[:-1]):
        return None
    types, diags = load_types(root)
    if any(t["path"] == rel for t in types) or any(d.get("path") == rel for d in diags):
        return None
    return diag("type_file_note", "", "not a type file (documentation?): a type file's frontmatter opens with a line of exactly --- and holds kind: mdbase.type", rel, None)


def check_root(root, engine, staged=False):
    """Every note under root. Staged: every note in git's index, with its indexed content (what the commit will contain);
    notes git does not track are not part of the commit and are skipped."""
    out = []
    if staged:
        for p, text in sorted(index_notes(root).items()):
            parts = os.path.relpath(p, root).split(os.sep)
            if "node_modules" in parts:
                continue
            d, _ = check_file(p, engine, text=text); out.extend(d)
        return out
    for dirpath, dirnames, files in os.walk(root):
        top_level = os.path.realpath(dirpath) == os.path.realpath(root)
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "node_modules"
                             and not (top_level and d in (TYPES_DIR, "_contracts")))   # reserved only at the root, as in check_file
        for f in sorted(files):
            if f.endswith(".md"):
                d, _ = check_file(os.path.join(dirpath, f), engine); out.extend(d)
    return out


STAGED_LINKS = []     # staged paths that carry no note content (symlinks and the like); a marker or type-file link still counts
STAGED_DELETED = []   # staged deletions


def staged_blobs():
    """Paths of staged (added, copied, modified, renamed) files and, for .md and .base, their STAGED content.
    The commit contains the index, not the working tree, so that is what must be checked."""
    top = git_top()
    r = subprocess.run(["git", "-C", top, "diff", "--cached", "--no-relative", "--no-renames", "--name-only", "-z", "--diff-filter=ACMRT"], capture_output=True)
    d = subprocess.run(["git", "-C", top, "diff", "--cached", "--no-relative", "--no-renames", "--name-only", "-z", "--diff-filter=D"], capture_output=True)
    STAGED_DELETED[:] = [os.path.join(top, x.decode("utf-8", errors="surrogateescape")) for x in d.stdout.split(b"\0") if x]
    regular = {p: sha for mode, sha, p in index_entries(top)} if top else {}
    files, blobs = [], {}
    for rel in [x.decode("utf-8", errors="surrogateescape") for x in r.stdout.split(b"\0") if x]:
        f = os.path.join(top, rel)
        if f not in regular or intent_to_add(regular[f], f):
            STAGED_LINKS.append(f)   # a symlink, a submodule or an intent-to-add entry: no note content goes into the commit
            continue
        files.append(f)
    wanted = [f for f in files if f.endswith((".md", ".base"))]
    for f, b in zip(wanted, cat_blobs([regular[f] for f in wanted])):   # one `git cat-file --batch` for every staged note
        blobs[f] = b.decode("utf-8", errors="replace") if b is not None else ""
    return files, blobs


# ---------- init: draft a type file from what already exists ----------
ENUM_MAX, ENUM_MIN_SHARE, MAX_RECORDS = 12, 0.5, 2000


def template_vocab(folder):
    """Read `_*template*.md` in the folder: `key: value   # a | b | c` comments become enums,
    other comments become descriptions. Returns {key: {"enum": [...], "description": str}}."""
    out = {}
    for f in sorted(os.listdir(folder)):
        if not (f.startswith("_") and "template" in f.lower() and f.endswith(".md")) or not os.path.isfile(os.path.join(folder, f)):
            continue
        text = open(os.path.join(folder, f), encoding="utf-8", errors="replace").read().lstrip("\ufeff")
        m = re.match(r"^---\r?\n(.*?)\r?\n---", text, re.S)
        if not m:
            continue
        for line in m.group(1).splitlines():
            km = re.match(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*(?:#\s*(.*))?$", line)
            if not km or km.group(3) is None:
                continue
            key, comment = km.group(1), km.group(3).strip()
            entry = out.setdefault(key, {})
            if "|" in comment and "YYYY" not in comment:
                vals = [v.strip().strip('"').strip("'") for v in comment.split("|")]
                vals = [v for v in vals if v and " " not in v and len(v) <= 30]
                if 2 <= len(vals) <= 30:
                    entry["enum"] = vals; continue
            entry["description"] = comment
    return out


def base_columns(folder):
    """Column order and display names from a sibling .base (its `properties:` block, first view's `order:`)."""
    import yaml
    for f in sorted(os.listdir(folder)):
        if f.endswith(".base"):
            try:
                b = yaml.safe_load(open(os.path.join(folder, f), encoding="utf-8")) or {}
            except Exception:
                continue
            if not isinstance(b, dict):
                continue   # not a Base this can read; base-check reports it
            props = b.get("properties") if isinstance(b.get("properties"), dict) else {}
            views = b.get("views") if isinstance(b.get("views"), list) else []
            order = []
            for v in views:
                o = v.get("order") if isinstance(v, dict) else None
                order = [str(c) for c in (o if isinstance(o, list) else []) if not str(c).startswith("file.")]
                if order: break
            return f, {str(k): v.get("displayName") for k, v in props.items()
                       if not str(k).startswith("file.") and isinstance(v, dict) and isinstance(v.get("displayName"), str)}, order
    return None, {}, []


def quoting_dumper():
    """A SafeDumper that quotes any string the YAML 1.2 core loader would read back as a number, bool or null
    ("1e5", "0o17", "true"), so a drafted type file accepts the records it was drafted from."""
    import yaml
    loader = core_loader()

    class Q(yaml.SafeDumper):
        def ignore_aliases(self, data):
            return True

    def rep_str(dumper, data):
        resolvers = loader.yaml_implicit_resolvers.get(data[:1] if data else None, []) + loader.yaml_implicit_resolvers.get(None, [])
        if any(rx.match(data) for tag, rx in resolvers):
            return dumper.represent_scalar("tag:yaml.org,2002:str", data, style='"')
        return dumper.represent_scalar("tag:yaml.org,2002:str", data)
    Q.add_representer(str, rep_str)
    return Q


def real_date(v):
    try:
        datetime.date.fromisoformat(v); return True
    except ValueError:
        return False


def glob_escape(text):
    """A folder name as a literal path_glob component: [ * ? match themselves."""
    return re.sub(r"([\[*?{])", r"[\1]", text)


def yaml_type(v):
    if v is None: return "null"
    if isinstance(v, bool): return "boolean"
    if isinstance(v, int): return "integer"
    if isinstance(v, float): return "number"
    if isinstance(v, list): return "array"
    if isinstance(v, dict): return "object"
    if isinstance(v, str): return "string"
    return "other"   # an explicit tag such as !!binary or !!timestamp: left untyped in the draft


def init_folder(folder, out_path=None):
    try:
        return _init_folder(folder, out_path)
    except OSError as e:
        cannot_run(f"frontmatter-schema-check init: {e.strerror or e}: {e.filename or folder}")


def _init_folder(folder, out_path=None):
    import yaml
    folder = os.path.abspath(folder.rstrip("/"))
    if not os.path.isdir(folder):
        cannot_run(f"frontmatter-schema-check init: {folder} is not a folder")
    kind = os.path.basename(folder).lstrip(".") or "notes"   # never a dotfile type name
    if kind.upper() in ("README", "TEMPLATE"):
        kind = kind.lower() + "-notes"   # _types/README.md and TEMPLATE.md are documentation, never a type
    files = sorted(f for f in os.listdir(folder) if is_candidate(os.path.join(folder, f), root=folder) and os.path.isfile(os.path.join(folder, f)))
    types, seen, n, unparsable = {}, {}, 0, []
    for f in files[:MAX_RECORDS]:
        try:
            fm, err = frontmatter(open(os.path.join(folder, f), encoding="utf-8", errors="replace").read())
        except OSError as e:
            fm, err = None, str(e)
        if err:
            unparsable.append(f); continue
        n += 1
        for k, v in fm.items():
            k = json_key(k)   # the key the validator will see
            t = yaml_type(v); types.setdefault(k, {}); types[k][t] = types[k].get(t, 0) + 1
            if t == "string":
                seen.setdefault(k, {}); seen[k][v] = seen[k].get(v, 0) + 1
    declared = {v for v in seen.get("type", {})} if types.get("type", {}).get("string") == n else set()
    if len(declared) == 1 and next(iter(declared)).upper() not in ("README", "TEMPLATE") and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", next(iter(declared))) and ".." not in next(iter(declared)):
        kind = next(iter(declared))   # records say `type: job`; name the type `job` so every engine agrees
    vocab = template_vocab(folder)
    base_file, display, order = base_columns(folder)
    keys = [k for k in order if k in types] + [k for k in types if k not in order]
    props = {}
    for k in keys:
        tcount = types[k]; present = sum(tcount.values())
        kinds = [t for t in tcount if t != "null"]
        prop = {}
        vals = seen.get(k, {})
        # a closed vocabulary: only strings, every value short and token-like, few distinct values, and they repeat
        datey = bool(vals) and all(re.fullmatch(r"\d{4}-\d{2}-\d{2}([T ][0-9:.+\-Z]+)?", v) for v in vals)
        enumerable = (kinds == ["string"] and vals and not datey and len(vals) <= ENUM_MAX and len(vals) <= max(2, n // 2)
                      and all(len(v) <= 40 and len(v.split()) <= 3 and not v.endswith(".") and "://" not in v for v in vals))
        if "enum" in vocab.get(k, {}) and kinds in ([], ["string"]):
            prop["enum"] = list(vocab[k]["enum"]) + [v for v in sorted(vals) if v not in vocab[k]["enum"]] + ([None] if tcount.get("null") else [])
        elif enumerable and tcount.get("string", 0) >= max(3, ENUM_MIN_SHARE * n):
            prop["enum"] = sorted(vals) + ([None] if tcount.get("null") else [])
        else:
            jt = sorted(set(kinds)) if kinds else ["string"]
            if tcount.get("null"): jt = jt + ["null"]
            if "other" not in jt:
                prop["type"] = jt[0] if len(jt) == 1 else jt
            if "string" in jt and vals and all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) and real_date(v) for v in vals):
                prop["format"] = "date"
            # date-time values are left as plain strings: their spellings vary too much for a strict format
        if vocab.get(k, {}).get("description"): prop["description"] = vocab[k]["description"]
        if display.get(k): prop["x-displayName"] = display[k]
        if present < n: prop["x-present-in"] = f"{present}/{n}"
        props[k] = prop
    if n == 0:
        cannot_run(f"frontmatter-schema-check init: no notes with frontmatter in {folder}; nothing to draft from")
    required = [k for k in keys if sum(types[k].values()) == n and n > 0]
    root = find_root(os.path.join(folder, "note.md"))   # exactly the root `check` finds for a note here
    if root is None:
        cannot_run(f"frontmatter-schema-check init: no {MARKER} in {folder} or the {MAX_UP} folders above it, so a draft would never "
                   f"apply. Mark the collection's top folder first: printf 'spec_version: \"0.3.0\"\\n' > <top folder>/{MARKER}")
    rel = os.path.relpath(folder, root)
    rel_glob = ("" if rel == "." else "/".join(glob_escape(p) for p in rel.split(os.sep)) + "/") + "*.md"
    doc = {"kind": "mdbase.type", "name": kind, "version": 1, "match": {"path_glob": rel_glob},
           "schema": {"dialect": "json-schema-2020-12", "value": {"type": "object", "additionalProperties": False,
                      "required": required, "properties": props}}}
    where = "the collection's top folder" if rel == "." else f"`{rel}/`"
    body = f"\n# {kind}\n\nDRAFT written by `frontmatter-schema-check init` on {datetime.date.today().isoformat()} from {n} records in {where}"
    body += (", the comments in the folder's template" if vocab else "") + (f", and `{base_file}`" if base_file else "") + ".\n"
    body += """
Its owner edits this file; nothing above was decided by a person yet.

- `enum` lists are the values seen (or the template's `a | b | c` comment). Strike typos, add missing legal values.
- `required` is every field present in all records. Remove what is optional.
- `x-present-in` marks fields missing from some records; decide required or optional, then delete the marker.
- `x-displayName` mirrors the Base column name; informational.
- Clock values (`20:00`) and `off`/`yes`/`no` are strings in both engines (YAML 1.2 core).
"""
    if unparsable:
        body += "\nFiles in the folder without usable frontmatter (not records, or broken):\n" + "".join(f"- `{f}`\n" for f in unparsable)
    text = "---\n" + yaml.dump(doc, Dumper=quoting_dumper(), sort_keys=False, allow_unicode=True, width=110) + "---\n" + body
    given_out = bool(out_path)
    out_path = out_path or os.path.join(root, TYPES_DIR, f"{kind}.md")
    if os.path.exists(out_path):
        cannot_run(f"frontmatter-schema-check init: {out_path} exists; it belongs to its owner now. " + ("Choose another --out file." if given_out else "Use --out to draft elsewhere."))
    if os.path.dirname(out_path):
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
    open(out_path, "w", encoding="utf-8").write(text)
    enums = sum(1 for p in props.values() if "enum" in p)
    return out_path, n, len(props), len(required), enums, unparsable


# ---------- base-check: an Obsidian .base file must load ----------
# Observed behaviour of Obsidian 1.x `base:query` (probed 2026-10-19):
#   * `obsidian base:query` prints `Error: ...` on stdout and EXITS 0 for a filter that is not an array
#     (`and:` null) and for broken YAML; it catches the same error whichever view is queried.
#   * It does NOT catch an unparseable formula, an unknown view type, or an unknown filter function: rows come back.
#   * `and: []` loads fine (Obsidian's rule is "must be an array", not "non-empty").
#   * Right after a write Obsidian may not have indexed the file yet: `Error: Base file not found`; poll briefly.
#   * The CLI hangs when the vault is not open: always under a timeout.
#   * Record frontmatter can never make a Base fail to open (bad records silently drop out of views), so this check
#     runs only for .base writes, never for record writes.
# The Obsidian CLI: FRONTMATTER_SCHEMA_CHECK_OBSIDIAN (a path, or "none" to switch the engine step off), else
# `obsidian` on PATH, else the macOS app.
OBSIDIAN = os.environ.get("FRONTMATTER_SCHEMA_CHECK_OBSIDIAN") or shutil.which("obsidian") or "/Applications/Obsidian.app/Contents/MacOS/obsidian"


def registered_vaults():
    """Vault folders Obsidian knows about (its own vault list). An unregistered folder cannot be queried by name."""
    for cfg in (os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json"),
                os.path.expanduser("~/.config/obsidian/obsidian.json")):
        try:
            data = json.load(open(cfg, encoding="utf-8"))
            return {os.path.realpath(v.get("path", "")) for v in (data.get("vaults") or {}).values() if v.get("path")}
        except (OSError, ValueError):
            continue
    return None
FILTER_KEYS = ("and", "or", "not")


def base_structure(path):
    """Offline check, same rule as Obsidian's parser: every and/or/not under a filters block is a list."""
    import yaml
    diags = []
    try:
        b = yaml.load(open(path, encoding="utf-8", errors="replace").read(), Loader=no_alias_safe_loader())
    except yaml.YAMLError as e:
        return [diag("base_yaml", "", str(e).splitlines()[0][:200], path, None)], None
    except RecursionError:
        return [diag("base_yaml", "", "nested too deeply", path, None)], None
    except OSError as e:
        return [diag("no_such_file", "", str(e)[:200], path, None)], None
    except Exception as e:   # a bad explicit tag (!!timestamp 2024-99-99, !!int abc) is the file's problem, not a crash
        return [diag("base_yaml", "", f"{type(e).__name__}: {str(e)[:160]}", path, None)], None
    if b is None:
        b = {}
    if not isinstance(b, dict):
        return [diag("base_structure", "", "a .base file must be a YAML mapping", path, None)], None

    def walk(node, where):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in FILTER_KEYS:
                    if not isinstance(v, list):
                        diags.append(diag("base_filter", f"{where}.{k}", f'"{k}" filter must be a list, found {type(v).__name__ if v is not None else "null"}', path, None))
                    else:
                        for i, item in enumerate(v):
                            walk(item, f"{where}.{k}[{i}]")
        elif node is not None and not isinstance(node, str):
            diags.append(diag("base_filter", where, "a filter must be a string expression or an and/or/not mapping", path, None))

    try:
        if "filters" in b:
            walk(b["filters"], "filters")
    except RecursionError:
        return [diag("base_filter", "filters", "filters nested too deeply", path, None)], None
    views = b.get("views")
    if views is not None and not isinstance(views, list):
        diags.append(diag("base_structure", "views", "views must be a list", path, None)); views = []
    first = None
    for i, v in enumerate(views or []):
        if isinstance(v, dict) and "filters" in v:
            try:
                walk(v["filters"], f"views[{i}].filters")
            except RecursionError:
                diags.append(diag("base_filter", f"views[{i}].filters", "filters nested too deeply", path, None))
            v = dict(v); v.pop("filters")
        if not isinstance(v, dict) or not v.get("name"):
            diags.append(diag("base_structure", f"views[{i}]", "each view needs a name", path, None)); continue
        first = first or str(v["name"])
        if "filters" in v:
            walk(v["filters"], f"views[{i}].filters")
    return diags, first


def base_lint(path, text=None):
    """Advisory rules for a .base (warn, never block). The column that opens the record when clicked should be first
    or second in every view, so a reader can always get from a row to its note. That column is `file.name`; a view whose `order:` lists columns must carry it in position one or two. A view with no `order:` shows
    every property and passes."""
    import yaml
    try:
        b = yaml.load(text if text is not None else open(path, encoding="utf-8", errors="replace").read(), Loader=no_alias_safe_loader()) or {}
    except Exception:   # base_structure reports broken files; the lint only reads good ones
        return []
    notes = []
    views = b.get("views") if isinstance(b, dict) else None
    for i, v in enumerate(views if isinstance(views, list) else []):
        if not isinstance(v, dict):
            continue
        order = v.get("order")
        if isinstance(order, list) and order and "file.name" not in [str(c) for c in order[:2]]:
            notes.append(diag("base_click_to_open", f"views[{i}].order",
                              f'view "{v.get("name", i)}": put file.name first or second in order (the column that opens the record)', path, None))
    return notes


def is_obsidian_base(path, text=None):
    """A *.base file is checked as an Obsidian Base only inside a vault (a .obsidian folder above it) and only when
    it looks like one: a YAML mapping with views/filters/properties/formulas, or unparseable text naming them.
    (A Dockerfile.base or other build file with the same suffix is left alone.)"""
    import yaml
    vault = vault_root(path)
    if not vault or any(part.startswith(".") for part in os.path.relpath(os.path.abspath(path), vault).split(os.sep) if part):
        return False   # hidden folders count only inside the vault: a vault in .claude/worktrees/ is a vault
    if text is None:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            return False
    try:
        b = yaml.safe_load(text)
    except Exception:   # broken YAML, a bad explicit tag, nesting too deep: decide by the top-level keys
        return bool(re.search(r"^(views|filters|properties|formulas):", text, re.M))
    return isinstance(b, dict) and any(k in b for k in ("views", "filters", "properties", "formulas"))


def base_check_staged(path, text):
    """Pre-commit check of a staged .base: the structure check runs on the staged content. The engine reads the file
    on disk, so it runs only when the staged content is what is on disk."""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".base", delete=False, encoding="utf-8") as tf:
        tf.write(text if text is not None else ""); tmp = tf.name
    try:
        diags, view = base_structure(tmp)
    finally:
        os.unlink(tmp)
    for d in diags:
        d["path"] = path
    if diags:
        return diags
    try:
        on_disk = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        on_disk = None
    if text is not None and on_disk != text:
        sys.stderr.write(f"note: {path} differs from its staged copy; Obsidian's engine check skipped, structure check passed\n")
        return []
    return base_check(path, strict_unreachable=True)[0]


def vault_root(path):
    d = os.path.dirname(os.path.abspath(path))
    for _ in range(10):
        if os.path.isdir(os.path.join(d, ".obsidian")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    return None


def base_engine(path, view, wait_s=4.0, timeout_s=10):
    """Return (diag or None, status) where status is ok | error | unreachable | no-vault | no-cli."""
    import time
    root = vault_root(path)
    if not root:
        return None, "no-vault"
    if OBSIDIAN == "none" or not os.path.exists(OBSIDIAN):
        return None, "no-cli"
    known = registered_vaults()
    if known is not None and os.path.realpath(root) not in known:
        return None, "unregistered-vault"
    rel = os.path.relpath(os.path.abspath(path), root)
    args = [OBSIDIAN, f"vault={os.path.basename(root)}", "base:query", f"path={rel}", "format=csv"] + ([f"view={view}"] if view else [])
    deadline = time.time() + wait_s
    while True:
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=timeout_s, stdin=subprocess.DEVNULL)
        except (subprocess.TimeoutExpired, OSError):
            return None, "unreachable"
        first = (r.stdout or r.stderr).lstrip().splitlines()[0] if (r.stdout or r.stderr).strip() else ""
        if first.startswith("Error: Base file not found") and time.time() < deadline:
            time.sleep(0.25); continue
        if first.startswith("Error:"):
            if "not found" in first.lower() and "vault" in first.lower():
                return None, "unreachable"
            return diag("base_engine", "", first[len("Error:"):].strip()[:240], path, None), "error"
        return None, "ok"


def base_check(path, strict_unreachable):
    """Diagnostics for one .base file. strict_unreachable: a commit gate fails closed when Obsidian cannot answer."""
    rel_path = path
    diags, view = base_structure(path)
    if diags:
        return diags, "structure"
    d, status = base_engine(path, view)
    if d:
        return [d], status
    if status == "unreachable" and strict_unreachable:
        return [diag("obsidian_unreachable", "", "Obsidian did not answer for this vault (not running, vault not open, or not known to it), so the Base could not be "
                     "checked by its engine. Open the vault in Obsidian and commit again.", rel_path, None)], status
    return [], status


# ---------- count: the shared "awaiting the human" tally ----------
def load_type_raw(root, rel):
    out = []
    tdir = os.path.join(root, TYPES_DIR)
    if not os.path.isdir(tdir):
        return out
    for dirpath, dirnames, files in os.walk(tdir):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "_contracts")
        for f in sorted(files):
            fp = os.path.join(dirpath, f)
            if not f.endswith(".md") or f in ("README.md", "TEMPLATE.md") or not os.path.isfile(fp):
                continue
            try:
                fm, err = frontmatter(open(fp, encoding="utf-8", errors="replace").read(), allow_aliases=True)
            except OSError:
                continue
            m = (fm or {}).get("match"); g = m.get("path_glob") if isinstance(m, dict) else None
            try:
                hit = not err and fm.get("kind") == "mdbase.type" and isinstance(g, str) and glob_to_regex(g).match(nfc(rel))
            except re.error:
                hit = False
            if hit:
                out.append(fm)
    return out


def value_label(x):
    """A field value as count shows it, spelled as YAML and JSON spell it: null, true, false, 3. A string that YAML
    would read as something else ("3", "true", "null") is shown quoted, so it never merges with the real value."""
    if x is None or isinstance(x, bool):
        return json.dumps(x)
    if isinstance(x, (list, dict)):
        return json.dumps(iso_dates(x), sort_keys=True)
    if isinstance(x, str):
        resolvers = core_loader().yaml_implicit_resolvers
        if x == "(missing)" or x.startswith(("[", "{", '"')) or any(rx.match(x) for _, rx in resolvers.get(x[:1] if x else None, []) + resolvers.get(None, [])):
            return json.dumps(x)   # a text value that would read as another value, or as a label count uses itself
        return x
    return str(x)


def count_folder(folder):
    try:
        return _count_folder(folder)
    except OSError as e:
        cannot_run(f"frontmatter-schema-check count: {e.strerror or e}: {e.filename or folder}")


def _count_folder(folder):
    folder = os.path.abspath(folder.rstrip("/"))
    root = find_root(os.path.join(folder, "x.md"))
    if root is None:
        cannot_run(f"frontmatter-schema-check count: no {MARKER} within {MAX_UP} levels above {folder}")
    names = sorted(f for f in os.listdir(folder) if is_candidate(os.path.join(folder, f), root=folder) and os.path.isfile(os.path.join(folder, f)))
    probe = os.path.relpath(os.path.join(folder, names[0] if names else "x.md"), root).replace(os.sep, "/")
    # The marker lives in a top-level extension block, `x-record-schema:` by convention; any `x-<name>:` block that carries
    # `awaiting_human` is accepted, so collections that adopted an earlier block name keep working.
    marks = [blk.get("awaiting_human") for t in load_type_raw(root, probe) for k, blk in
             sorted(t.items(), key=lambda kv: kv[0] != "x-record-schema") if str(k).startswith("x-") and isinstance(blk, dict)]
    mark = next((m for m in marks if isinstance(m, dict) and isinstance(m.get("field"), str) and m.get("field")), None)
    field = mark["field"] if mark else None
    values = mark.get("values") if mark else None
    if mark and values is not None and not isinstance(values, list):
        cannot_run(f"frontmatter-schema-check count: awaiting_human.values must be a list, such as [waiting], found {type(values).__name__}")
    awaiting_values = [value_label(x) for x in (values or []) if not isinstance(x, (list, dict))] if mark else []
    by, total, unparsable = {}, 0, 0
    for f in names:
        try:
            fm, err = frontmatter(open(os.path.join(folder, f), encoding="utf-8", errors="replace").read())
        except OSError:
            fm, err = None, "unreadable"
        if err:
            unparsable += 1; continue
        total += 1
        if field:
            v = "(missing)" if field not in fm else value_label(fm[field])
            by[v] = by.get(v, 0) + 1
    awaiting = sum(n for v, n in by.items() if v in awaiting_values) if field else None
    return {"folder": os.path.relpath(folder, root), "field": field, "awaiting_values": awaiting_values,
            "total": total, "awaiting": awaiting, "by_value": by, "unparsable": unparsable}


# ---------- rule 6: output ----------
def render(diags, max_lines):
    """Wrong values first, then one line per record listing its missing required fields, then everything else.
    (Otherwise dozens of "required" lines can bury the one wrong value.)"""
    order = {"schema_enum": 0, "schema_type": 0, "schema_const": 0, "schema_format": 0, "schema_pattern": 0,
             "schema_additional_properties": 1, "frontmatter_unparsable": 0, "base_filter": 0, "base_yaml": 0, "base_engine": 0}
    missing = {}
    rest = []
    for d in diags:
        if d["code"] == "schema_required":
            missing.setdefault(d["path"], []).append(d["field"])
        else:
            rest.append(d)
    rest.sort(key=lambda d: order.get(d["code"], 0 if d["code"].startswith("schema_") else 2))
    lines = []
    for d in rest:
        lines.append(f"{d['path']}" + (f": {d['field']}" if d.get("field") else "") + f": {d['message']}")
    for path, fields in missing.items():
        shown = ", ".join(fields[:8]) + (f", and {len(fields) - 8} more" if len(fields) > 8 else "")
        lines.append(f"{path}: missing required field{'s' if len(fields) > 1 else ''} ({len(fields)}): {shown}")
    out = lines[:max_lines]
    if len(lines) > max_lines:
        out.append(f"... {len(lines) - max_lines} more")
    types = sorted({d["type"] for d in diags if d.get("type")})
    return out, types


__version__ = "0.1.0"


def uncovered_folder(folder):
    """True when folder sits in a collection and holds notes, but no type file's glob covers any of them."""
    root = find_root(os.path.join(folder, "x.md"))
    if root is None:
        return False
    try:
        notes = [f for f in os.listdir(folder) if f.endswith(".md") and is_candidate(os.path.join(folder, f), root=root)]
    except OSError:
        return False
    types, diags = load_types(root)
    if not notes or diags:
        return False
    rels = [os.path.relpath(os.path.join(folder, f), root).replace(os.sep, "/") for f in notes]
    return not any(t["glob"] and glob_to_regex(t["glob"]).match(nfc(r)) for t in types for r in rels)


def hook_main(payload_text, engine, max_lines):
    home = os.path.expanduser("~")
    try:
        payload = json.loads(payload_text)
        if not isinstance(payload, dict):
            return 0
        ti = payload.get("tool_input")
        path = (ti.get("file_path") if isinstance(ti, dict) else "") or ""
    except Exception:
        return 0
    if not path:
        return 0
    if not isinstance(path, str):
        return 0
    if path.endswith(".base") and os.path.isfile(path) and is_obsidian_base(path):
        diags, status = base_check(path, strict_unreachable=False)
        home = os.path.expanduser("~")
        notes = base_lint(path)
        if diags:
            lines, _ = render(diags + notes, max_lines)
            text = ("frontmatter-schema-check WARNING: this Obsidian Base will not load. The write went through; fix it now, because "
                    "the commit will be refused until it loads.\n" + "\n".join(lines) + f"\nbase: {tilde(path)}")
        elif notes:
            lines, _ = render(notes, max_lines)
            text = ("frontmatter-schema-check note: this Base loads, but a view breaks a house rule (advisory; commits are not refused for it).\n"
                    + "\n".join(lines) + f"\nbase: {tilde(path)}")
        elif find_root(os.path.join(os.path.dirname(path), "x.md")) is None and any(
                f.endswith(".md") and is_candidate(os.path.join(os.path.dirname(path), f), root=os.path.dirname(path)) for f in os.listdir(os.path.dirname(path))):
            # A Base beside records but no schema: this is a mini database being born. Have the agent give it a schema
            # now, so a new collection gets its schema from the agent that created it.
            folder = os.path.dirname(path)
            text = ("frontmatter-schema-check: this folder has an Obsidian Base but no schema, so its records are not checked. Give it one now: "
                    f"`printf 'spec_version: \"0.3.0\"\\n' > {shlex.quote(os.path.join(folder, 'mdbase.yaml'))} && frontmatter-schema-check init {shlex.quote(folder)}`, "
                    "then read the drafted _types/<folder>.md (confirm enums, set required), run `frontmatter-schema-check check` on the records, "
                    "and commit the type file with them. If this repo has no pre-commit hook, also run `frontmatter-schema-check install-git-hook <repo>`.")
        elif uncovered_folder(os.path.dirname(path)):
            # A Base beside notes inside a collection, but no type file covers them: same moment, the collection already exists.
            folder = os.path.dirname(path)
            text = ("frontmatter-schema-check: this folder has an Obsidian Base but no type file covers its notes, so they are not checked. "
                    f"Give it one now: `frontmatter-schema-check init {shlex.quote(folder)}`, then read the drafted type file (confirm enums, "
                    "set required), run `frontmatter-schema-check check` on the notes, and commit the type file with them.")
        elif status == "unreachable":
            text = ("frontmatter-schema-check WARNING: Obsidian did not answer, so only the offline structure check ran on "
                    f"{tilde(path)}. Open its vault before you commit; the commit check needs the engine.")
        else:
            return 0
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))
        return 0
    root = find_root(path) if path.endswith(".md") else None
    if root and os.path.relpath(os.path.abspath(path), root).split(os.sep)[0] == TYPES_DIR:
        # A type file was written: check that it loads, since a broken one stops every note in the collection being checked.
        rel = os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path)), os.path.realpath(root))
        mine = [d for d in load_types(root)[1] if d.get("path") in (rel, rel.replace(os.sep, "/"), TYPES_DIR)]   # TYPES_DIR: a symlinked _types
        u = unusable_type_file(path, root) if os.path.isfile(path) else None
        if u: mine.append(u)
        if mine and all(d["code"] == "type_file_note" for d in mine):
            text = f"frontmatter-schema-check note: {mine[0]['path']}: {mine[0]['message']}"
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))
            return 0
        if mine:
            lines, _ = render(mine, max_lines)
            text = ("frontmatter-schema-check WARNING: this type file does not load, so no note in its collection is checked until it is "
                    "fixed. The write went through; fix it now, because the commit will be refused.\n" + "\n".join(lines) + f"\ntype file: {tilde(path)}")
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))
        return 0
    diags, info = check_file(path, engine)
    if not diags:
        if isinstance(info, str) and info.startswith("note:"):
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                  "additionalContext": "frontmatter-schema-check note (advisory): " + info[5:]}}))
        return 0
    lines, types = render(diags, max_lines)
    root = find_root(path)
    home = os.path.expanduser("~")
    tfiles = []
    if root:
        loaded, _ = load_types(root)
        tfiles = [os.path.join(root, t["path"]) for t in loaded if t["name"] in types] or [os.path.join(root, TYPES_DIR)]
    shown = ", ".join(tilde(f) for f in tfiles) or TYPES_DIR
    try:
        logdir = os.environ.get("FRONTMATTER_SCHEMA_CHECK_STATE") or os.path.join(home, ".local/state/frontmatter-schema-check"); os.makedirs(logdir, exist_ok=True)
        with open(os.path.join(logdir, "hook-failures.jsonl"), "a", encoding="utf-8") as lf:
            lf.write(json.dumps({"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                                 "path": tilde(path), "tool": payload.get("tool_name"),
                                 "session": payload.get("session_id"), "cwd": tilde(payload.get("cwd")) if isinstance(payload.get("cwd"), str) else None,
                                 "n": len(diags), "codes": sorted({d["code"] for d in diags}),
                                 "first": lines[0] if lines else ""}) + "\n")
    except OSError:
        pass
    if all(d["code"].startswith("type_file_") for d in diags):
        head = ("frontmatter-schema-check WARNING: a type file in this collection is broken, so records here cannot be checked. "
                "Tell whoever owns the type file; commits touching this collection will be refused until it is fixed.")
        shown = ", ".join(sorted({tilde(os.path.join(root, d["path"])) for d in diags})) if root else shown
    else:
        head = ("frontmatter-schema-check WARNING: the record you just wrote does not match its type file. The write went through; "
                "fix the field now, because the commit will be refused until it matches.")
    text = head + "\n" + "\n".join(lines) + f"\nschema: {shown}"
    # A warning, not an error: exit 0 with additionalContext, which Claude Code adds next to the tool result.
    # The hard block is the pre-commit gate (`check --staged`, exit 1): warn where the agent can fix it at once,
    # block where nothing can slip past.
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))
    return 0


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")   # a lone surrogate in a field name must not crash the report
        except (AttributeError, ValueError):
            pass
    return _main(argv)


def _main(argv):
    args = list(argv); as_json = "--json" in args; engine = "auto"; max_lines = 5
    if args[:1] in (["--version"], ["-V"]):
        print(f"frontmatter-schema-check {__version__}"); return 0
    try:
        import yaml, jsonschema  # noqa: F401  (fail clearly, not with a traceback, when run outside its environment)
    except ImportError as e:
        sys.stderr.write(f"frontmatter-schema-check: missing dependency ({e.name}); install with `pipx install git+https://github.com/johntrandall/frontmatter-schema-check` "
                         "or `pip install PyYAML jsonschema`\n")
        return 0 if args[:1] == ["hook"] else 2
    if "hook" in args and all(a.startswith("-") or (i and args[i - 1] in ("--engine", "--max-lines")) for i, a in enumerate(args[:args.index("hook")])):
        args = ["hook"] + [a for i, a in enumerate(args) if i != args.index("hook")]
    if args[:1] == ["hook"]:
        # The hook never fails a tool call, whatever its arguments: a bad option falls back to the default.
        engine, max_lines = "auto", 5
        if "--engine" in args and args.index("--engine") + 1 < len(args) and args[args.index("--engine") + 1] in ("auto", "python", "mdbase"):
            engine = args[args.index("--engine") + 1]
        if "--max-lines" in args and args.index("--max-lines") + 1 < len(args) and args[args.index("--max-lines") + 1].isdigit():
            max_lines = max(1, int(args[args.index("--max-lines") + 1]))
        try:
            return hook_main(payload_text=sys.stdin.read(), engine=engine, max_lines=max_lines)
        except Exception as e:
            sys.stderr.write(f"frontmatter-schema-check hook: internal error ignored ({type(e).__name__}: {str(e)[:120]})\n")
            return 0
    max_lines_given = False
    for flag in ("--engine", "--max-lines", "--out"):
        if flag in args and (args.index(flag) + 1 >= len(args) or args[args.index(flag) + 1].startswith("--")):
            sys.stderr.write(f"frontmatter-schema-check: {flag} needs a value\n"); return 64
    if "--engine" in args:
        i = args.index("--engine"); engine = args[i + 1]; del args[i:i + 2]
        if engine not in ("auto", "python", "mdbase"):
            sys.stderr.write("frontmatter-schema-check: --engine is auto, python or mdbase\n"); return 64
    if "--max-lines" in args:
        i = args.index("--max-lines")
        try:
            max_lines = int(args[i + 1])
        except ValueError:
            sys.stderr.write("frontmatter-schema-check: --max-lines needs a number\n"); return 64
        if max_lines < 1:
            sys.stderr.write("frontmatter-schema-check: --max-lines must be 1 or more\n"); return 64
        max_lines_given = True; del args[i:i + 2]
    args = [a for a in args if a != "--json"]
    if not args:
        sys.stderr.write(__doc__.strip() + "\n"); return 64
    if args[0] in ("-h", "--help") or any(a in ("-h", "--help") for a in args[1:]):
        print(__doc__.strip()); return 0
    verb, rest = args[0], args[1:]
    known = {"check": {"--staged"}, "init": {"--out"}}.get(verb, set())
    unknown = [a for i, a in enumerate(rest) if a.startswith("-") and a not in known and not (i and rest[i - 1] == "--out" and verb == "init")]
    if unknown:
        sys.stderr.write(f"frontmatter-schema-check: unknown option {unknown[0]} (see --help)\n"); return 64
    if verb == "hook":
        try:
            return hook_main(payload_text=sys.stdin.read(), engine=engine, max_lines=max_lines)
        except Exception as e:  # the hook must never fail a tool call
            sys.stderr.write(f"frontmatter-schema-check hook: internal error ignored ({type(e).__name__}: {str(e)[:120]})\n")
            return 0
    if verb == "install-git-hook":
        if len(rest) != 1:
            sys.stderr.write("frontmatter-schema-check install-git-hook <repo>\n"); return 64
        repo = os.path.abspath(rest[0])
        if subprocess.run(["git", "-C", repo, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True).stdout.strip() != "true":
            sys.stderr.write(f"frontmatter-schema-check: {repo} is not a git work tree\n"); return 2
        # A worktree's .git is a file; hooks live in the common git dir, so resolve it through git.
        r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True)
        hooks = os.path.join(r.stdout.strip(), "hooks") if r.returncode == 0 and r.stdout.strip() else os.path.join(repo, ".git", "hooks")
        # core.hooksPath (husky and friends) moves the hooks git actually runs; write there, never to an unread folder.
        hp_cfg = subprocess.run(["git", "-C", repo, "config", "--get", "core.hooksPath"], capture_output=True, text=True).stdout.strip()
        if hp_cfg:
            top = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or repo
            hooks = os.path.join(top, os.path.expanduser(hp_cfg)) if not os.path.isabs(os.path.expanduser(hp_cfg)) else os.path.expanduser(hp_cfg)
            print(f"note: core.hooksPath is set; using {hooks}")
        if ".husky" in os.path.abspath(hooks).split(os.sep):
            print(f"{hooks}: husky manages this repo's hooks; add `frontmatter-schema-check check --staged` to .husky/pre-commit instead"); return 2
        try:
            os.makedirs(hooks, exist_ok=True) if r.returncode == 0 else None
        except OSError as e:
            print(f"{hooks}: cannot create the hooks folder ({e.strerror or e}); not modified"); return 2
        if not os.path.isdir(hooks):
            sys.stderr.write(f"frontmatter-schema-check: {repo} is not a git work tree with .git/hooks\n"); return 2
        # GUI git clients run hooks with a short PATH. Use the command on PATH; else this exact interpreter and module,
        # which have the dependencies; if neither exists, skip rather than block every commit (README, "Pre-commit check").
        py, mod = sys.executable, os.path.realpath(__file__)
        line = ('if command -v frontmatter-schema-check >/dev/null 2>&1; then frontmatter-schema-check check --staged || exit 1; '
                f'elif [ -x {shlex.quote(py)} ] && [ -f {shlex.quote(mod)} ]; then {shlex.quote(py)} {shlex.quote(mod)} check --staged || exit 1; fi  # frontmatter-schema-check')
        def install_into(hp, dry=False):
            if not os.path.islink(hp) and (os.path.isdir(hp) or (os.path.exists(hp) and not os.access(hp, os.R_OK | os.W_OK))
                                           or (not os.path.exists(hp) and not os.access(hooks, os.W_OK))):
                print(f"{hp}: cannot be read and written (a folder, or no permission); not modified")
                return 2
            if os.path.islink(hp):
                # Appending would edit the link's target, often a tracked file, and a shell line appended to a Python hook breaks
                # every commit. Never write through a link.
                print(f"{hp}: is a symlink to {os.path.realpath(hp)}; not modified. Call `frontmatter-schema-check check --staged` from that "
                      "hook yourself (exit non-zero when it fails).")
                return 2
            empty = os.path.isfile(hp) and not open(hp, encoding="utf-8", errors="replace").read().strip()   # does nothing: start fresh
            if os.path.exists(hp) and not empty:
                body = open(hp, encoding="utf-8", errors="replace").read()
                # Only lines this tool wrote (they end with its marker comment); a line the user wrote is theirs.
                old = [l for l in body.split("\n") if "check --staged" in l and re.search(r"#\s*(record-schema|frontmatter-schema-check)\s*$", l)]
                if old:
                    if old == [line]:
                        if not dry: print(f"{hp}: already installed")
                        return 0
                    # An earlier version's line: `cmd && {...}` fails the whole hook when the tool is missing and is the
                    # last line. Replace it in place with the current line.
                    if dry: return 0
                    body = "\n".join(line if l in old else l for l in body.split("\n"))
                    mode = os.stat(hp).st_mode
                    open(hp, "w", encoding="utf-8").write(body); os.chmod(hp, mode)
                    print(f"{hp}: upgraded the check line"); return 0
                if re.search(r"call_lefthook|\blefthook\b[^\n]*\brun\b|LEFTHOOK", body):
                    print(f"{hp}: lefthook manages this repo; add `frontmatter-schema-check check --staged` to its lefthook.yml instead"); return 2
                first = body.split("\n", 1)[0]
                shell = first.startswith("#!") and re.search(r"(^|[/ ])(sh|bash|zsh|dash|ksh)(\s|$)", first[2:].strip()) is not None
                if not shell:
                    print(f"{hp}: existing hook is not a shell script ({first[:60] or 'no shebang'}); not modified. Call "
                          "`frontmatter-schema-check check --staged` from it yourself (exit non-zero when it fails).")
                    return 2
                # Insert right after the shebang: an existing `exit 0` further down must not skip the check.
                head, _, tail = body.partition("\n")
                body = head + "\n" + line + "\n" + tail
            else:
                body = "#!/bin/sh\n" + line + "\n"
            if dry: return 0
            existed = os.path.exists(hp) and not empty   # an empty hook is replaced like a missing one, executable
            mode = os.stat(hp).st_mode if existed else 0o755
            open(hp, "w", encoding="utf-8").write(body); os.chmod(hp, mode)
            if existed and not mode & 0o111:
                print(f"note: {hp} is not executable, so git does not run it; left as it was")
            print(f"{hp}: installed"); return 0
        names = ("pre-commit", "pre-merge-commit")   # a merge commit runs pre-merge-commit, not pre-commit
        for name in names:   # refuse before writing either, so a refusal changes nothing
            rc = install_into(os.path.join(hooks, name), dry=True)
            if rc:
                return rc
        for name in names:
            try:
                install_into(os.path.join(hooks, name))
            except OSError as e:
                sys.stderr.write(f"frontmatter-schema-check: {e.filename or name}: {e.strerror or e}\n"); return 2
        return 0
    if verb == "base-check":
        if not rest:
            sys.stderr.write("frontmatter-schema-check base-check <file.base>...\n"); return 64
        diags = []
        for f in rest:
            if not os.path.isfile(f):
                diags.append(diag("no_such_file", "", "no such file", f, None)); continue
            if not is_obsidian_base(f):
                if not as_json:
                    print(f"{f}: skipped (not an Obsidian Base: outside a vault, or no views, filters, properties or formulas)")
                continue
            d, status = base_check(f, strict_unreachable=True); diags.extend(d)
            notes = base_lint(f)
            if not as_json:
                print(f"{f}: {'ok' if not d else 'FAIL'} ({status})")
                for n in notes:
                    print(f"  note (not blocking): {n['field']}: {n['message']}")
        if as_json:
            print(json.dumps({"valid": not diags, "diagnostics": diags}, indent=2))
        elif diags:
            lines, _ = render(diags, 50); print("\n".join(lines))
        return 1 if diags else 0
    if verb == "count":
        if len(rest) != 1:
            sys.stderr.write("frontmatter-schema-check count <folder>\n"); return 64
        if not os.path.isdir(rest[0]):
            sys.stderr.write(f"frontmatter-schema-check: {rest[0]} is not a folder\n"); return 2
        r = count_folder(rest[0])
        if as_json:
            print(json.dumps(r, indent=2, sort_keys=True))
        else:
            tail = (f", awaiting {r['awaiting']} ({r['field']} is {' or '.join(r['awaiting_values'])})" if r["awaiting_values"]
                    else f", no awaiting values listed for {r['field']}") if r["field"] else ", no x-record-schema.awaiting_human marker in a type file whose match.path_glob covers this folder"
            print(f"{r['folder']}: {r['total']} record{'s' if r['total'] != 1 else ''}{tail}" + (f", {r['unparsable']} unparsable" if r["unparsable"] else ""))
        return 0
    if verb == "init":
        out = None
        if "--out" in rest:
            i = rest.index("--out"); out = rest[i + 1]; del rest[i:i + 2]
            if not out.strip():
                sys.stderr.write("frontmatter-schema-check: --out needs a file name\n"); return 64
        if len(rest) != 1:
            sys.stderr.write("frontmatter-schema-check init <folder> [--out <type file>]\n"); return 64
        path, n, nf, nr, ne, unp = init_folder(rest[0], out)
        print(f"wrote {os.path.relpath(path)}: {n} record{'s' if n != 1 else ''}, {nf} field{'s' if nf != 1 else ''}, {nr} required, {ne} enum{'s' if ne != 1 else ''}" + (f", {len(unp)} file{'s' if len(unp) != 1 else ''} without usable frontmatter listed" if unp else ""))
        return 0
    if verb == "check":
        files, staged = rest, rest == ["--staged"]
        blobs = {}
        if staged:
            if subprocess.run(["git", "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
                sys.stderr.write("frontmatter-schema-check: check --staged must run inside a git repository\n"); return 2
            files, blobs = staged_blobs()
            global STAGED, STAGED_MARKERS
            STAGED = True   # every type file, staged or not, is read as the commit holds it
            STAGED_MARKERS = {os.path.realpath(os.path.dirname(p)) for _, sha, p in index_entries(git_top(), symlinks=True)
                              if os.path.basename(p) == MARKER and not intent_to_add(sha, p)}   # a symlinked marker is present too: only presence matters
        elif "--staged" in rest:
            sys.stderr.write("frontmatter-schema-check: --staged takes no file arguments\n"); return 64
        elif not rest:
            sys.stderr.write("frontmatter-schema-check check <file>... | check --staged\n"); return 64
        diags = []
        roots_full = set()
        if staged:
            # A staged file that a tracked type-file symlink points at changes that type file: check its collection.
            staged_real = {os.path.realpath(f) for f in files}
            for mode, sha, p in index_entries(git_top(), symlinks=True):
                if mode == b"120000" and os.sep + TYPES_DIR + os.sep in p and os.path.realpath(link_target(p, sha)) in staged_real:
                    r0 = find_root(p)
                    if r0: roots_full.add(r0)
        if staged:
            for f in STAGED_LINKS:   # a staged marker or type-file link: its collection changes
                r0 = find_root(f)
                if r0 and (os.path.basename(f) == MARKER or os.path.relpath(f, r0).split(os.sep)[0] == TYPES_DIR):
                    roots_full.add(r0)
            for f in STAGED_DELETED:   # a deleted marker hands its notes to the collection above; a deleted type file frees them
                if os.path.basename(f) == MARKER:
                    r0 = find_root(os.path.dirname(f))
                    if r0: roots_full.add(r0)
                else:
                    r0 = find_root(f)
                    if r0 and os.path.relpath(f, r0).split(os.sep)[0] == TYPES_DIR: roots_full.add(r0)
        if not staged and "--out" in rest:
            sys.stderr.write("frontmatter-schema-check: --out belongs to init\n"); return 64
        for f in files:
            if not staged and os.path.isdir(f):
                sys.stderr.write(f"frontmatter-schema-check: {f} is a folder; pass its files (for example {f}/*.md)\n"); return 2
            root = find_root(f)
            if root and os.path.relpath(os.path.abspath(f), root).split(os.sep)[0] == TYPES_DIR:
                if not staged and not os.path.exists(f):
                    diags.append(diag("no_such_file", "", "no such file", f, None)); continue
                u = unusable_type_file(f, root) if not staged else None
                if u: sys.stderr.write(f"note (not blocking): {u['path']}: {u['message']}\n")
                roots_full.add(root); continue
            if staged and os.path.basename(f) == MARKER and root:
                roots_full.add(root); continue   # a newly marked collection: every note in it now counts
            if not staged and os.path.isdir(f):
                sys.stderr.write(f"frontmatter-schema-check: {f} is a folder; pass its files (for example {f}/*.md)\n"); return 2
            if f.endswith(".base"):
                text = blobs.get(f)
                if not staged and not os.path.exists(f):
                    diags.append(diag("no_such_file", "", "no such file", f, None)); continue
                if is_obsidian_base(f, text):
                    d = base_check_staged(f, text) if staged else base_check(f, strict_unreachable=True)[0]
                    diags.extend(d)
                    for n in base_lint(f, text):
                        sys.stderr.write(f"note (not blocking): {n['path']}: {n['field']}: {n['message']}\n")
                continue
            d, info = check_file(f, engine, text=blobs.get(f) if staged else None); diags.extend(d)
            if isinstance(info, str) and info.startswith("note:"):
                sys.stderr.write("note (not blocking): " + info[5:] + "\n")
            if not staged and not os.path.exists(f):
                diags.append(diag("no_such_file", "", "no such file", f, None))
        for root in sorted(roots_full):
            diags.extend(load_types(root)[1])   # a broken type file is reported even when no note would read it
            diags.extend(check_root(root, engine, staged))
        seen = set(); uniq = []
        for d in diags:
            k = json.dumps(d, sort_keys=True)
            if k not in seen: seen.add(k); uniq.append(d)
        if as_json:
            print(json.dumps({"valid": not uniq, "diagnostics": uniq}, indent=2))
        elif uniq:
            lines, _ = render(uniq, max_lines if max_lines_given else 50)
            if all(d["code"].startswith("type_file_") for d in uniq):
                print("a type file is invalid, so no note in its collection was checked; fix the type file:")
            print("\n".join(lines))
        return 1 if uniq else 0
    sys.stderr.write(f"frontmatter-schema-check: unknown verb {verb}\n"); return 64


def cli():
    sys.exit(main(sys.argv[1:]))


if __name__ == "__main__":
    cli()

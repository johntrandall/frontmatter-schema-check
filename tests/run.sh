#!/usr/bin/env bash
# frontmatter-schema-check tests: a shipped fixture (20 clean book records), broken copies, non-record files, hook mode, both engines.
# The mdbase engine is exercised only when an `mdbase` binary is on PATH.
set -u; cd "$(dirname "$0")/.."; RS=./frontmatter_schema_check.py; fail=0
python3 -c 'import yaml, jsonschema' 2>/dev/null || { echo "tests/run.sh: python3 needs PyYAML and jsonschema; run in a venv after: pip install -e ." >&2; exit 2; }
for tool in git jq perl; do command -v $tool >/dev/null || { echo "tests/run.sh: needs $tool" >&2; exit 2; }; done
export FRONTMATTER_SCHEMA_CHECK_OBSIDIAN=none   # hermetic: never call a real Obsidian app
T=$(mktemp -d); export FRONTMATTER_SCHEMA_CHECK_STATE="$T/state"; trap 'rm -rf "$T"' EXIT
cp -R tests/fixtures/library "$T/c"
sed -i.bak 's/^format: .*/format: carrier-pigeon/' "$T/c/books/b01.md" && mv "$T/c/books/b01.md.bak" "$T/c/b01.md.orig"
printf -- '---
type: book
title: x
format: ebook
year: 2000
undeclared_field: yes
---
# b
' > "$T/c/books/bogus-extra.md"
printf -- '---\ntype: book\n---\n# m\n' > "$T/c/books/bogus-missing.md"
printf -- '# plain note\n' > "$T/c/books/notes.md"            # untyped by schema? no: glob matches, no frontmatter → unparsable
printf -- '---\ntitle: x\n---\n# outside\n' > "$T/outside.md"        # no collection → silent
ok(){ printf '  ok   %s\n' "$1"; }; bad(){ printf '  FAIL %s\n' "$1"; fail=1; }
for eng in python mdbase; do
  command -v mdbase >/dev/null || [ "$eng" = python ] || { echo "  skip mdbase engine (not on PATH)"; continue; }
  echo "engine: $eng"
  clean=$(ls tests/fixtures/library/books/*.md)
  $RS check --engine $eng $clean >/dev/null && ok "20 clean fixture records pass" || bad "clean records should pass"
  out=$($RS check --engine $eng --json "$T/c/books/b01.md" "$T/c/books/bogus-extra.md" "$T/c/books/bogus-missing.md" "$T/c/books/notes.md")
  n=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["diagnostics"]))')
  [ "$n" -ge 4 ] && ok "broken records: $n diagnostics (enum, additional, required..., unparsable)" || bad "expected >=4 diagnostics, got $n: $out"
  printf '%s' "$out" | grep -q 'carrier-pigeon' && ok "enum message names the value" || bad "enum message missing"
  printf '%s' "$out" | grep -q 'undeclared_field' && ok "additionalProperties caught" || bad "additionalProperties missed"
  $RS check --engine $eng "$T/outside.md" >/dev/null && ok "file outside any collection is silent" || bad "outside file should pass"
  $RS check --engine $eng "$T/c/_types/book.md" >/dev/null; rc=$?; [ $rc -eq 1 ] && ok "staged type file validates its whole root (fails on the broken copies)" || bad "type-file path should validate root, rc=$rc"
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$T/c/books/b01.md" | $RS hook --engine $eng 2>"$T/err"); rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse" and (.hookSpecificOutput.additionalContext|test("WARNING") and test("carrier-pigeon") and test("schema: "))' >/dev/null && [ ! -s "$T/err" ] && ok "hook: warning via additionalContext, exit 0" || { bad "hook warning wrong (rc=$rc)"; echo "$out"; cat "$T/err"; }
  git -C "$T" init -q 2>/dev/null; git -C "$T" add c/mdbase.yaml c/_types c/books/b01.md 2>/dev/null; (cd "$T" && $OLDPWD/$RS check --staged --engine $eng >/dev/null); rc=$?
  [ $rc -eq 1 ] && ok "pre-commit (check --staged): hard block, exit 1" || bad "check --staged should exit 1, got $rc"
  printf '{"tool_input":{"file_path":"%s"}}' "$T/outside.md" | $RS hook --engine $eng 2>"$T/err"; rc=$?
  [ $rc -eq 0 ] && [ ! -s "$T/err" ] && ok "hook: silent exit 0 on non-record" || bad "hook should be silent on non-record"
done
echo "base-check:"
B=$T/b; mkdir -p "$B/.obsidian"
printf 'views:\n  - type: table\n    name: A\n    filters:\n      and:\n        - file.name != "x"\n' > "$B/good.base"
printf 'views:\n  - type: table\n    name: A\n    filters:\n      and:\n' > "$B/nulland.base"
printf 'views:\n  - type: table\n    name: [oops\n' > "$B/badyaml.base"
$RS base-check "$B/good.base" >/dev/null && ok "base-check: good Base passes (offline, no vault)" || bad "good base"
$RS base-check "$B/nulland.base" >/dev/null; [ $? -eq 1 ] && ok "base-check: null and-filter refused" || bad "null and"
$RS base-check "$B/badyaml.base" >/dev/null; [ $? -eq 1 ] && ok "base-check: broken YAML refused" || bad "bad yaml"
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$B/nulland.base" | $RS hook); [ $? -eq 0 ] && printf '%s' "$o" | jq -e '.hookSpecificOutput.additionalContext|test("will not load")' >/dev/null && ok "hook: .base warns, exit 0" || bad "base hook: $o"
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$B/good.base" | $RS hook); [ -z "$o" ] && ok "hook: good .base silent" || bad "good base hook spoke: $o"
git -C "$T" add -f b/nulland.base 2>/dev/null; (cd "$T" && $OLDPWD/$RS check --staged >/dev/null); [ $? -eq 1 ] && ok "pre-commit: staged broken .base blocks" || bad "staged base should block"
N=$T/newdb; mkdir -p "$N/.obsidian"; printf -- '---\na: 1\n---\n' > "$N/one.md"; cp "$B/good.base" "$N/_n.base"
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$N/_n.base" | $RS hook); printf '%s' "$o" | jq -e '.hookSpecificOutput.additionalContext|test("no schema") and test("frontmatter-schema-check init")' >/dev/null && ok "hook: new Base beside records with no schema nudges init" || bad "no-schema nudge: $o"
printf 'views:\n  - type: table\n    name: A\n    order:\n      - title\n      - status\n      - file.name\n' > "$B/lint.base"
printf 'views:\n  - type: table\n    name: A\n    order:\n      - title\n      - file.name\n  - type: table\n    name: B\n' > "$B/lintok.base"
$RS base-check "$B/lint.base" > "$T/lint.out"; rc=$?; [ $rc -eq 0 ] && grep -q 'file.name first or second' "$T/lint.out" && ok "base-check: click-to-open rule is a non-blocking note" || bad "lint rc=$rc $(cat $T/lint.out)"
$RS base-check "$B/lintok.base" | grep -q note && bad "lint false positive" || ok "base-check: file.name second, and a view with no order, pass"
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$B/lint.base" | $RS hook); printf '%s' "$o" | jq -e '.hookSpecificOutput.additionalContext|test("advisory")' >/dev/null && ok "hook: rule surfaces as an advisory note" || bad "lint hook: $o"
echo "count:"
c=$($RS count --json tests/fixtures/tasks/tasks)
printf '%s' "$c" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert (d["total"],d["awaiting"],d["by_value"])==(5,2,{"waiting":2,"doing":1,"done":2}), d' && ok "count: generic fixture (x-record-schema marker) total 5, awaiting 2" || bad "count tasks fixture: $c"
N2=$T/nullmark; mkdir -p $N2/_types $N2/intake; printf 'spec_version: "0.3.0"\n' > $N2/mdbase.yaml
printf -- '---\nkind: mdbase.type\nname: intake\nmatch: {path_glob: "intake/*.md"}\nx-record-schema:\n  awaiting_human: {field: processed, values: [null]}\nschema: {dialect: json-schema-2020-12, value: {type: object}}\n---\n' > $N2/_types/intake.md
printf -- '---\nprocessed: null\n---\n' > $N2/intake/a.md; printf -- '---\nprocessed: done\n---\n' > $N2/intake/b.md
$RS count --json $N2/intake | python3 -c 'import json,sys; d=json.load(sys.stdin); assert (d["awaiting"],d["awaiting_values"])==(1,["null"]), d' && ok "count: a null marker value counts null records" || bad "null marker count"
W=$T/wtrepo; git init -q $W; git -C $W commit -q --allow-empty -m init; git -C $W worktree add -q $T/wt 2>/dev/null; $RS install-git-hook $T/wt >/dev/null && grep -q '# frontmatter-schema-check' $W/.git/hooks/pre-commit && ok "install-git-hook from a worktree writes the common hooks dir" || bad "worktree install"
printf -- '---\ntype: book\ntitle: stray\n---\n' > $T/c/stray.md
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$T/c/stray.md" | $RS hook); printf '%s' "$o" | jq -e '.hookSpecificOutput.additionalContext|test("NOT checked")' >/dev/null && ok "orphan type: record outside its type's glob gets an advisory note" || bad "orphan note: $o"
$RS check "$T/c/stray.md" 2>/dev/null; [ $? -eq 0 ] && ok "orphan type note never blocks a commit" || bad "orphan note blocked"
D2=$T/dates; mkdir -p $D2; for i in 1 2 3 4; do printf -- '---\ncreated: 2026-10-1%s\nkind: x\n---\n' $i > $D2/r$i.md; done; printf 'spec_version: "0.3.0"\n' > $T/mdbase.yaml
$RS init $D2 --out $T/dates-type.md >/dev/null; grep -A2 'created:' $T/dates-type.md | grep -q 'format: date' && ! grep -A3 'created:' $T/dates-type.md | grep -q enum && ok "init: date fields get format date, not an enum" || { bad "init dates"; grep -A4 'created:' $T/dates-type.md; }
for k in py link bash; do g=$T/h-$k; git init -q $g; case $k in
  py) printf '#!/usr/bin/env python3\nprint("hi")\n' > $g/.git/hooks/pre-commit;;
  link) printf '#!/usr/bin/env python3\nprint("hi")\n' > $g/real-hook; ln -s $g/real-hook $g/.git/hooks/pre-commit;;
  bash) printf '#!/usr/bin/env bash\necho hi\n' > $g/.git/hooks/pre-commit;; esac
  before=$(cat $g/.git/hooks/pre-commit); $RS install-git-hook $g >/dev/null 2>&1; rc=$?; after=$(cat $g/.git/hooks/pre-commit)
  case $k in py|link) [ $rc -eq 2 ] && [ "$before" = "$after" ] && ok "install-git-hook refuses a $k hook and leaves it untouched" || bad "install-git-hook $k rc=$rc";;
  bash) [ $rc -eq 0 ] && bash -n $g/.git/hooks/pre-commit && grep -q frontmatter-schema-check $g/.git/hooks/pre-commit && ok "install-git-hook appends to a bash hook, still parses" || bad "bash hook";; esac
done
echo "regressions:"
R=$T/reg; mkdir -p $R; cp -R tests/fixtures/library $R/lib
perl -pi -e 's/^format: .*/format: scroll/' $R/lib/books/b03.md
# 1 mdbase engine fails closed on a config error
if command -v mdbase >/dev/null; then cp -R $R/lib $R/lib2; : > $R/lib2/mdbase.yaml; $RS check --engine mdbase $R/lib2/books/b03.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "mdbase engine fails closed on a config error" || bad "mdbase fail-open"; fi
# 3 check --staged validates the index, not the working tree
G=$R/g; git init -q $G; cp -R tests/fixtures/library $G/lib; git -C $G add -A; git -C $G -c user.email=t@t -c user.name=t commit -q -m init
perl -pi -e 's/^format: .*/format: scroll/' $G/lib/books/b05.md; git -C $G add lib/books/b05.md; perl -pi -e 's/^format: .*/format: ebook/' $G/lib/books/b05.md
(cd $G && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "staged bad content blocks even when the working copy is fixed" || bad "staged reads working tree"
git -C $G checkout -q -- lib/books/b05.md 2>/dev/null; git -C $G reset -q; perl -pi -e 's/^title: .*/title: "Renamed"/' $G/lib/books/b06.md; git -C $G add lib/books/b06.md; perl -pi -e 's/^format: .*/format: scroll/' $G/lib/books/b06.md
(cd $G && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "staged good content passes even when the working copy is broken" || bad "staged false block"
# 6 install-git-hook: exit 0 in an existing hook, and core.hooksPath
H=$R/h; git init -q $H; printf '#!/bin/sh\necho checks\nexit 0\n' > $H/.git/hooks/pre-commit; $RS install-git-hook $H >/dev/null; [ "$(sed -n 2p $H/.git/hooks/pre-commit | grep -c frontmatter-schema-check)" = 1 ] && ok "install-git-hook inserts before an existing exit 0" || bad "exit 0 hook"
HP=$R/hp; git init -q $HP; git -C $HP config core.hooksPath .githooks; mkdir -p $HP/.githooks; $RS install-git-hook $HP >/dev/null 2>&1; [ -f $HP/.githooks/pre-commit ] && ok "install-git-hook writes to core.hooksPath" || bad "hooksPath ignored"
# 7 YAML leading zeros stay strings, never crash
Y=$R/y; mkdir -p $Y/_types $Y/r; printf 'spec_version: "0.3.0"\n' > $Y/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: z\nmatch: {path_glob: "r/*.md"}\nschema: {dialect: json-schema-2020-12, value: {type: object, properties: {zip: {type: string}}}}\n---\n' > $Y/_types/z.md
printf -- '---\nzip: 01234\n---\n' > $Y/r/a.md; printf -- '---\nzip: 09876\n---\n' > $Y/r/b.md; out=$($RS check $Y/r/a.md $Y/r/b.md 2>&1); [ $? -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback && ok "leading-zero numbers are strings (01234, 09876)" || bad "leading zeros: $out"
# 8 an uncompilable schema is the type file's fault, not a traceback
printf -- '---\nkind: mdbase.type\nname: z\nmatch: {path_glob: "r/*.md"}\nschema: {dialect: json-schema-2020-12, value: {type: object, properties: {zip: {type: strin}}}}\n---\n' > $Y/_types/z.md
out=$($RS check $Y/r/a.md 2>&1); printf '%s' "$out" | grep -q 'schema does not compile' && ! printf '%s' "$out" | grep -q Traceback && ok "uncompilable schema reported, no traceback" || bad "uncompilable: $out"
# 9 a ../ path is still checked
(cd $R/lib/books && $OLDPWD/$RS check ../books/b03.md >/dev/null 2>&1); [ $? -eq 1 ] && ok "../ relative path is checked" || bad "../ path skipped"
# 10 a README in _types does not break the collection
printf '# types\n' > $R/lib/_types/README.md; $RS check tests/fixtures/library/books/b01.md $R/lib/books/b01.md >/dev/null 2>&1 && ok "_types/README.md is documentation, not a broken type file" || bad "_types README"
# 11 a non-Obsidian *.base in a vault is left alone
V=$R/v; mkdir -p $V/.obsidian; printf 'FROM python:3.12\nRUN echo hi\n' > $V/Dockerfile.base; out=$(printf '{"tool_input":{"file_path":"%s"}}' "$V/Dockerfile.base" | $RS hook); [ -z "$out" ] && ok "Dockerfile.base is not treated as an Obsidian Base" || bad "Dockerfile.base: $out"
# 13 argument errors exit 64, no traceback
for a in "check --engine" "check x.md --max-lines x" "check x.md --engine bogus" "init /no/such/dir"; do out=$($RS $a 2>&1); rc=$?; [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q Traceback && ok "bad arguments handled: $a" || bad "args '$a' rc=$rc $out"; done
# 14 count: a missing field is not null
mkdir -p $R/cm/_types $R/cm/t; printf 'spec_version: "0.3.0"\n' > $R/cm/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: t\nmatch: {path_glob: "t/*.md"}\nx-record-schema:\n  awaiting_human: {field: processed, values: [null]}\nschema: {dialect: json-schema-2020-12, value: {type: object}}\n---\n' > $R/cm/_types/t.md
printf -- '---\nprocessed: null\n---\n' > $R/cm/t/a.md; printf -- '---\nother: 1\n---\n' > $R/cm/t/b.md
$RS count --json $R/cm/t | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["awaiting"]==1 and d["by_value"].get("(missing)")==1, d' && ok "count: a missing field is not counted as null" || bad "count missing"
# 4 init names the type after the records' own type
mkdir -p $R/it/films; printf 'spec_version: "0.3.0"\n' > $R/it/mdbase.yaml; for i in 1 2 3; do printf -- '---\ntype: film\ntitle: f%s\n---\n' $i > $R/it/films/f$i.md; done
(cd $R/it && $OLDPWD/$RS init films >/dev/null) && grep -q '^name: film$' $R/it/_types/film.md && ok "init names the type after the records' type: value" || bad "init type name"

echo "regressions, correctness review:"
Q=$T/q; mkdir -p $Q; cp -R tests/fixtures/library $Q/lib
# --engine mdbase really calls mdbase (fake binary that logs and reports invalid)
mkdir -p $Q/fakebin; printf '#!/bin/sh\necho "$@" >> %s/mdbase.log\necho '"'"'{"diagnostics":[{"code":"x","field":"f","message":"fake","path":"books/b14.md"}],"valid":false}'"'"'\nexit 1\n' $Q > $Q/fakebin/mdbase; chmod +x $Q/fakebin/mdbase
PATH="$Q/fakebin:$PATH" $RS check --engine mdbase $Q/lib/books/b14.md >/dev/null 2>&1; rc=$?; [ $rc -eq 1 ] && grep -q validate $Q/mdbase.log && ok "--engine mdbase runs mdbase" || bad "--engine mdbase did not run (rc=$rc)"
# a fresh installed hook does not fail the commit when the tool is not on PATH
HG=$Q/hg; git init -q $HG; $RS install-git-hook $HG >/dev/null; sed -i.bak 's#echo "[^"]*")#echo "/nonexistent")#' $HG/.git/hooks/pre-commit; echo x > $HG/a.txt; git -C $HG add a.txt
(cd $HG && PATH=/usr/bin:/bin git -c user.email=t@t -c user.name=t -c core.hooksPath=.git/hooks commit -q -m x >/dev/null 2>&1); [ $? -eq 0 ] && ok "installed hook lets a commit through when the tool cannot be found" || bad "hook blocks when tool missing"
# an old-style line is upgraded in place
HU=$Q/hu; git init -q $HU; printf '#!/bin/sh\ncommand -v record-schema >/dev/null && { record-schema check --staged || exit 1; }  # record-schema\n' > $HU/.git/hooks/pre-commit; chmod 755 $HU/.git/hooks/pre-commit
$RS install-git-hook $HU | grep -q upgraded && grep -q 'if \[ -x' $HU/.git/hooks/pre-commit && ! grep -q 'command -v record-schema >/dev/null &&' $HU/.git/hooks/pre-commit && ok "install-git-hook upgrades an old check line in place" || bad "upgrade old line"
# odd type-file shapes: no traceback, hook exits 0
for shape in 'match: "notes/*.md"\nschema: {value: {type: object}}' 'match: {path_glob: "notes/*.md"}\nschema: "oops"' 'match: {path_glob: "notes/[z-a].md"}\nschema: {value: {type: object}}'; do
  O=$Q/odd$RANDOM; mkdir -p $O/_types $O/notes; printf 'spec_version: "0.3.0"\n' > $O/mdbase.yaml; printf -- "---\nkind: mdbase.type\nname: h\n$shape\n---\n" > $O/_types/h.md; printf -- '---\na: 1\n---\n' > $O/notes/r.md
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$O/notes/r.md" | $RS hook 2>&1); rc=$?; [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback && printf '%s' "$out" | grep -q 'type file' && ok "odd type-file shape reported, hook exit 0" || bad "odd shape rc=$rc $out"
done
# staged type files come from the index
GS=$Q/gs; git init -q $GS; cp -R tests/fixtures/library $GS/lib; git -C $GS add -A; git -C $GS -c user.email=t@t -c user.name=t commit -q -m init
cp $GS/lib/_types/book.md $Q/book.orig; perl -0pi -e 's/enum: \[hardcover, paperback, ebook\]/enum: [hardcover]/' $GS/lib/_types/book.md; git -C $GS add lib/_types/book.md; cp $Q/book.orig $GS/lib/_types/book.md
(cd $GS && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a staged narrowed type file is applied (records now invalid)" || bad "staged type file read from disk"
# init round-trips strings that look like numbers
IR=$Q/ir; mkdir -p $IR/things; printf 'spec_version: "0.3.0"\n' > $IR/mdbase.yaml; for i in 1 2 3 4; do printf -- '---\ncode: "1e5"\nver: "0o17"\nflag: "true"\n---\n' > $IR/things/t$i.md; done
(cd $IR && $OLDPWD/$RS init things >/dev/null) && $RS check $IR/things/*.md >/dev/null && ok "init draft accepts its own records (1e5, 0o17, true as text)" || bad "init round-trip"
# YAML alias bomb is refused quickly
AB=$Q/ab; mkdir -p $AB/_types $AB/r; printf 'spec_version: "0.3.0"\n' > $AB/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: z\nmatch: {path_glob: "r/*.md"}\nschema: {dialect: json-schema-2020-12, value: {type: object}}\n---\n' > $AB/_types/z.md
printf -- '---\na: &a [x,x,x,x,x,x,x,x,x,x]\nb: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]\nc: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]\nd: [*c,*c,*c,*c,*c,*c,*c,*c,*c,*c]\n---\n' > $AB/r/bomb.md
s0=$(date +%s); out=$($RS check $AB/r/bomb.md 2>&1); s1=$(date +%s); [ $((s1-s0)) -le 3 ] && printf '%s' "$out" | grep -q 'aliases' && ok "YAML aliases refused (no expansion)" || bad "alias bomb: $out"
# a type file may use YAML anchors and aliases; init never writes them
TA=$Q/ta; mkdir -p $TA/_types $TA/r; printf 'spec_version: "0.3.0"\n' > $TA/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: z\nmatch: {path_glob: "r/*.md"}\nschema: {dialect: json-schema-2020-12, value: {type: object, properties: {a: &s {type: string}, b: *s}}}\n---\n' > $TA/_types/z.md
printf -- '---\na: x\nb: y\n---\n' > $TA/r/ok.md; $RS check $TA/r/ok.md >/dev/null 2>&1 && ok "aliases allowed in a type file" || bad "type-file alias refused"
grep -q -E '&id|\*id' $IR/_types/*.md && bad "init wrote YAML aliases" || ok "init writes no YAML aliases"
out=$($RS check $Q/odd*/notes/r.md 2>/dev/null | head -1); printf '%s' "$out" | grep -q 'no note in its collection was checked' && ok "broken type file says no note was checked" || bad "type-file message: $out"
# exit codes
L=$Q/lib/books
$RS check $L/nope.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "check of a missing file exits 1" || bad "missing file rc"
$RS check $L >/dev/null 2>&1; [ $? -eq 2 ] && ok "check of a folder exits 2" || bad "folder rc"
$RS check >/dev/null 2>&1; [ $? -eq 64 ] && ok "check with no arguments exits 64" || bad "no args rc"
$RS check --staged $L/b01.md >/dev/null 2>&1; [ $? -eq 64 ] && ok "--staged with file arguments exits 64" || bad "--staged + files rc"
(cd /tmp && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 2 ] && ok "check --staged outside git exits 2" || bad "staged outside git rc"
$RS base-check >/dev/null 2>&1; [ $? -eq 64 ] && ok "base-check with no arguments exits 64" || bad "base-check no args rc"
out=$($RS base-check $Q/nope.base 2>&1); [ $? -eq 1 ] && ! printf '%s' "$out" | grep -q Traceback && ok "base-check of a missing file exits 1, no traceback" || bad "base-check missing: $out"
out=$($RS count $Q/nope 2>&1); [ $? -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && ok "count of a missing folder exits 2, no traceback" || bad "count missing: $out"
$RS check --max-lines -1 $L/b01.md >/dev/null 2>&1; [ $? -eq 64 ] && ok "--max-lines must be positive" || bad "negative max-lines"

echo "regressions, second correctness review:"
Z=$T/z; mkdir -p $Z; cp -R tests/fixtures/library $Z/lib; perl -pi -e 's/^format: .*/format: scroll/' $Z/lib/books/b03.md
hk(){ printf '%s' "$1" | $RS hook 2>&1; }
out=$(hk "{\"tool_input\":{\"file_path\":\"$Z/lib/books/b03.md\"},\"cwd\":5}"); rc=$?; [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback && printf '%s' "$out" | grep -q WARNING && ok "hook: non-string cwd" || bad "hook cwd int rc=$rc $out"
python3 -c "print('---\ne: ' + '['*20000 + ']'*20000 + '\n---')" > $Z/lib/books/deep.md; out=$(hk "{\"tool_input\":{\"file_path\":\"$Z/lib/books/deep.md\"}}"); rc=$?; [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback && ok "hook: deeply nested frontmatter" || bad "deep note rc=$rc"
$RS check $Z/lib/books/deep.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "check: deeply nested frontmatter is a problem, not a crash" || bad "deep check"
VB=$Z/vb; mkdir -p $VB/.obsidian; printf 'views: 5\n' > $VB/v5.base; out=$(hk "{\"tool_input\":{\"file_path\":\"$VB/v5.base\"}}"); rc=$?; [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback && ok "hook: .base with views: 5" || bad "views 5 rc=$rc $out"
$RS base-check $VB/v5.base >/dev/null 2>&1; [ $? -eq 1 ] && ok "base-check: views must be a list" || bad "views 5 base-check"
python3 - $VB/bomb.base <<'PY'
import sys
lines=["filters:","  and:","    - &a {and: [x]}"]
prev="a"
for i in range(8):
    nm=f"l{i}"; lines.append(f"    - &{nm} {{and: [{', '.join(['*'+prev]*9)}]}}"); prev=nm
open(sys.argv[1],"w").write("\n".join(lines)+"\n")
PY
s0=$(date +%s); $RS base-check $VB/bomb.base >/dev/null 2>&1; rc=$?; s1=$(date +%s); [ $rc -eq 1 ] && [ $((s1-s0)) -le 3 ] && ok "alias bomb in a .base refused quickly" || bad "base bomb rc=$rc $((s1-s0))s"
TB=$Z/tb; mkdir -p $TB/_types $TB/r; printf 'spec_version: "0.3.0"\n' > $TB/mdbase.yaml; printf -- '---\na: 1\n---\n' > $TB/r/x.md
python3 - $TB/_types/z.md <<'PY'
import sys
L=["---","kind: mdbase.type","name: z","match: {path_glob: \"r/*.md\"}","schema:","  dialect: json-schema-2020-12","  value:","    d0: &d0 {type: object}"]
for i in range(1,9): L.append(f"    d{i}: &d{i} {{allOf: [{', '.join(['*d'+str(i-1)]*9)}]}}")
L.append("    allOf: [*d8]"); L.append("---")
open(sys.argv[1],"w").write("\n".join(L)+"\n")
PY
s0=$(date +%s); out=$($RS check $TB/r/x.md 2>&1); s1=$(date +%s); [ $((s1-s0)) -le 5 ] && printf '%s' "$out" | grep -q 'too many nodes' && ok "alias bomb in a type file refused quickly" || bad "type bomb $((s1-s0))s $out"
CN=$Z/cn; mkdir -p $CN/_types/sub $CN/t/x.md; printf 'spec_version: "0.3.0"\n' > $CN/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: t\nmatch: {path_glob: "t/*.md"}\nx-record-schema:\n  awaiting_human: {field: s, values: [w]}\nschema: {dialect: json-schema-2020-12, value: {type: object}}\n---\n' > $CN/_types/sub/t.md; printf -- '---\ns: w\n---\n' > $CN/t/a.md
out=$($RS count --json $CN/t 2>&1); printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["awaiting"]==1 and d["total"]==1, d' && ok "count: type file in a _types subfolder, a folder named x.md skipped" || bad "count subfolder: $out"
$RS check $VB/missing.base >/dev/null 2>&1; [ $? -eq 1 ] && ok "check of a missing .base exits 1" || bad "missing .base"
IT=$Z/it; mkdir -p $IT/trav; printf 'spec_version: "0.3.0"\n' > $IT/mdbase.yaml; for i in 1 2 3; do printf -- '---\ntype: "../../escaped"\n---\n' > $IT/trav/n$i.md; done
(cd $IT && $OLDPWD/$RS init trav >/dev/null 2>&1); [ ! -e $IT/../escaped.md ] && [ -f $IT/_types/trav.md ] && ok "init never writes outside _types (unsafe type: name)" || bad "init traversal"
NR=$(mktemp -d); mkdir -p $NR/plain $NR/gh; out=$(GIT_CONFIG_GLOBAL=$NR/gc git config -f $NR/gc core.hooksPath $NR/gh; GIT_CONFIG_GLOBAL=$NR/gc $RS install-git-hook $NR/plain 2>&1); rc=$?; [ $rc -eq 2 ] && [ ! -e $NR/gh/pre-commit ] && ok "install-git-hook refuses a folder that is not a repository" || bad "non-repo install rc=$rc $out"
FB=$Z/fb; git init -q $FB; cp -R tests/fixtures/library $FB/lib; $RS install-git-hook $FB >/dev/null; perl -pi -e 's/^format: .*/format: scroll/' $FB/lib/books/b02.md; git -C $FB add -A
(cd $FB && env -i HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FRONTMATTER_SCHEMA_CHECK_STATE="$FRONTMATTER_SCHEMA_CHECK_STATE" PATH=/usr/bin:/bin git -c user.email=t@t -c user.name=t commit -q -m x >/dev/null 2>&1); [ $? -eq 1 ] && ok "hook fallback (this interpreter + module) blocks a bad commit under a minimal PATH" || bad "fallback under minimal PATH"
perl -pi -e 's/^format: .*/format: ebook/' $FB/lib/books/b02.md; git -C $FB add -A; (cd $FB && env -i HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FRONTMATTER_SCHEMA_CHECK_STATE="$FRONTMATTER_SCHEMA_CHECK_STATE" PATH=/usr/bin:/bin git -c user.email=t@t -c user.name=t commit -q -m y >/dev/null 2>&1); [ $? -eq 0 ] && ok "hook fallback lets a good commit through under a minimal PATH" || bad "fallback good commit"
PG=$Z/pg; mkdir -p $PG/_types $PG/n; printf 'spec_version: "0.3.0"\n' > $PG/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: p\nmatch: {path_glob: 5}\nschema: {value: {type: object}}\n---\n' > $PG/_types/p.md; printf -- '---\na: 1\n---\n' > $PG/n/a.md
$RS check $PG/n/a.md 2>&1 | grep -q 'path_glob must be one string' && ok "a non-string path_glob is reported" || bad "non-string glob"
CT=$Z/ct; mkdir -p $CT/_types/_contracts $CT/n; printf 'spec_version: "0.3.0"\n' > $CT/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: k\nmatch: {path_glob: "n/*.md"}\nschema: {value: {type: object, required: [must]}}\n---\n' > $CT/_types/_contracts/k.md; printf -- '---\na: 1\n---\n' > $CT/n/a.md
$RS check $CT/n/a.md >/dev/null 2>&1 && ok "_types/_contracts is skipped" || bad "_contracts in _types loaded"
DT=$Z/dt; mkdir -p $DT/ev; printf 'spec_version: "0.3.0"\n' > $DT/mdbase.yaml; for w in "2026-01-01 10:00" "2026-01-02 11:00" "2026-01-03"; do printf -- "---\nwhen: \"$w\"\n1: x\n---\n" > "$DT/ev/$RANDOM.md"; done
(cd $DT && $OLDPWD/$RS init ev >/dev/null) && $RS check $DT/ev/*.md >/dev/null 2>&1 && ok "init draft accepts its notes (mixed date-times, a numeric key)" || bad "init date-time or numeric key"
printf -- '---\n---\n# empty\n' > $Z/lib/books/empty.md; out=$($RS check $Z/lib/books/empty.md 2>&1); printf '%s' "$out" | grep -q 'no frontmatter' && bad "empty frontmatter treated as none: $out" || ok "empty frontmatter is an empty mapping, not 'no frontmatter'"

echo "regressions, README cold read round 4:"
ST=$Z/st; git init -q $ST; cp -R tests/fixtures/library $ST/lib; git -C $ST add -A; git -C $ST -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null commit -q -m base
printf '\n' >> $ST/lib/_types/book.md; git -C $ST add lib/_types/book.md; git -C $ST add lib/books/b02.md; perl -pi -e 's/^format: .*/format: scroll/' $ST/lib/books/b02.md
(cd $ST && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "staged type file: a staged note is read from the index, not from its unstaged disk edit" || bad "staged type file read the disk copy of a staged note"
git -C $ST add lib/books/b02.md; git -C $ST checkout -- lib/books/b02.md 2>/dev/null; perl -pi -e 's/^format: .*/format: ebook/' $ST/lib/books/b02.md
(cd $ST && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "staged type file: a bad staged note blocks even when its disk copy is fixed" || bad "staged type file missed a bad staged note"
$RS init $Z/no-such-folder >/dev/null 2>&1; [ $? -eq 2 ] && ok "init on a missing folder exits 2" || bad "init missing folder exit code"
NM=$(mktemp -d); mkdir -p $NM/f; $RS count $NM/f >/dev/null 2>&1; [ $? -eq 2 ] && ok "count without mdbase.yaml exits 2" || bad "count without root exit code"
LH=$Z/lh; git init -q $LH; printf '#!/bin/sh\n# lefthook\nlefthook run pre-commit\n' > $LH/.git/hooks/pre-commit; $RS install-git-hook $LH >/dev/null 2>&1; [ $? -eq 2 ] && ok "install-git-hook refuses lefthook with exit 2" || bad "lefthook refusal exit code"

echo "regressions, correctness review round 4:"
W=$Z/w4; mkdir -p $W/db; for i in 1 2 3; do printf -- "---\ntitle: t$i\nstatus: open\n---\n" > $W/db/n$i.md; done; printf 'spec_version: "0.3.0"\n' > $W/db/mdbase.yaml
$RS init $W/db >/dev/null 2>&1 && [ -f $W/db/_types/db.md ] && grep -q "path_glob: '\*.md'" $W/db/_types/db.md && ok "init on a collection's own top folder writes its _types there" || bad "init on the root folder"
printf -- '---\ntitle: 5\nstatus: open\n---\n' > $W/db/bad.md; $RS check $W/db/bad.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a draft for the top folder applies to its notes" || bad "root draft never applies"
(cd $W/db && $OLDPWD/$RS init . --out draft.md >/dev/null 2>&1) && [ -f $W/db/draft.md ] && ok "init --out with a bare file name" || bad "init --out bare name"
NO=$(mktemp -d); mkdir -p $NO/nomark/notes; cp $W/db/n1.md $NO/nomark/notes/; $RS init $NO/nomark/notes >/dev/null 2>&1; [ $? -eq 2 ] && [ ! -e $NO/nomark/_types ] && ok "init with no mdbase.yaml in reach refuses (exit 2) and writes nothing" || bad "init without root"
mkdir -p "$W/g/Books [2024]"; printf 'spec_version: "0.3.0"\n' > $W/g/mdbase.yaml; for i in 1 2 3; do printf -- "---\nwhen: 2026-02-3$((i-1))\nd: !!binary aGVsbG8=\n---\n" > "$W/g/Books [2024]/n$i.md"; done
$RS init "$W/g/Books [2024]" >/dev/null 2>&1 && $RS check "$W/g/Books [2024]"/n*.md >/dev/null 2>&1 && ok "init: explicit tags and impossible dates do not crash or reject their notes" || bad "init tags/dates"
printf -- '---\nwhen: 5\nd: x\n---\n' > "$W/g/Books [2024]/bad.md"; $RS check "$W/g/Books [2024]/bad.md" >/dev/null 2>&1; [ $? -eq 1 ] && ok "init escapes glob characters in a folder name, and the draft applies" || bad "glob characters in folder name"
mkdir -p $W/t/f; printf 'spec_version: "0.3.0"\n' > $W/t/mdbase.yaml; printf -- '---\nstatus: open   # open | done\n---\n' > $W/t/f/_template.md; for v in open done waiting; do printf -- "---\nstatus: $v\n---\n" > $W/t/f/$v.md; done; printf -- '- a\n' > $W/t/f/odd.base
$RS init $W/t/f >/dev/null 2>&1 && $RS check $W/t/f/*.md >/dev/null 2>&1 && ok "init: a template enum gains the values seen, and a malformed sibling .base is ignored" || bad "init template enum or odd .base"
printf -- '---\nd: 1\nd: 2\n---\n' > $W/db/dup.md; $RS check $W/db/dup.md 2>&1 | grep -q "duplicate key" && ok "duplicate keys are refused (YAML 1.2)" || bad "duplicate keys accepted"
printf '\xef\xbb\xbf---\ntitle: t\nstatus: open\n---\n' > $W/db/bom.md; $RS check $W/db/bom.md >/dev/null 2>&1 && ok "a byte order mark before --- is not 'no frontmatter'" || bad "BOM"
$RS check --frob $W/db/n1.md >/dev/null 2>&1; [ $? -eq 64 ] && ok "an unknown option exits 64" || bad "unknown option"
$RS check --help >/dev/null 2>&1 && ok "check --help prints help" || bad "check --help"
$RS >/dev/null 2>&1; [ $? -eq 64 ] && ok "no arguments exits 64" || bad "no arguments exit code"
mkdir -p $W/c/_types $W/c/tasks; printf 'spec_version: "0.3.0"\n' > $W/c/mdbase.yaml; printf -- '---\ns: w\n---\n' > $W/c/tasks/a.md; printf -- '---\ns: true\n---\n' > $W/c/tasks/b.md
printf -- '---\nkind: mdbase.type\nname: t\nmatch: {path_glob: "tasks/*.md"}\nx-record-schema:\n  awaiting_human: {field: s, values: 5}\nschema: {value: {type: object}}\n---\n' > $W/c/_types/t.md
$RS count $W/c/tasks >/dev/null 2>&1; [ $? -eq 2 ] && ok "count: a non-list values is refused (exit 2), not a traceback" || bad "count values 5"
perl -pi -e 's/values: 5/values: [w, true]/' $W/c/_types/t.md; out=$($RS count --json $W/c/tasks 2>&1); printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["awaiting"]==2 and "true" in d["by_value"], d' && ok "count spells booleans true/false, as YAML does" || bad "count booleans: $out"
printf -- '---\nkind: mdbase.type\nname: x\nmatch: {path_glob: 5}\nschema: {value: {type: object}}\n---\n' > $W/c/_types/x.md; out=$(printf '{"tool_input":{"file_path":"%s"}}' "$W/c/_types/x.md" | $RS hook); [ $? -eq 0 ] && printf '%s' "$out" | grep -q "type file does not load" && ok "hook warns when an agent writes a broken type file" || bad "hook silent on broken type file: $out"
HG=$Z/hg; git init -q $HG; printf '#!/bin/sh\nfrontmatter-schema-check check --staged --max-lines 3 || exit 1\n' > $HG/.git/hooks/pre-commit; $RS install-git-hook $HG >/dev/null 2>&1; grep -q -- '--max-lines 3' $HG/.git/hooks/pre-commit && ok "install-git-hook keeps a check line the user wrote" || bad "install-git-hook rewrote a user's line"
printf 'FROM x\n' > $W/db/Dockerfile.base; out=$($RS base-check $W/db/Dockerfile.base 2>&1); [ $? -eq 0 ] && printf '%s' "$out" | grep -q skipped && ok "base-check skips a .base that is not an Obsidian Base" || bad "base-check Dockerfile.base: $out"

echo "regressions, README cold read round 5:"
SC=$Z/sc; mkdir -p $SC/_types $SC/n; printf 'spec_version: "0.3.0"\n' > $SC/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: n\nmatch: {path_glob: "n/*.md"}\nschema: {value: {type: object, properties: {title: {type: strng}}}}\n---\n' > $SC/_types/n.md; printf -- '---\ntitle: a\n---\n' > $SC/n/a.md
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$SC/_types/n.md" | $RS hook); printf '%s' "$out" | grep -q "schema does not compile" && ok "hook warns when a written type file's schema does not compile" || bad "hook silent on a schema that does not compile: $out"
out=$($RS check $SC/n/a.md 2>&1); [ $? -eq 1 ] && printf '%s' "$out" | grep -q "no note in its collection was checked" && ok "check reports a schema that does not compile as a type-file error" || bad "check on uncompilable schema: $out"

echo "regressions, correctness review round 5:"
mk5() { git init -q -b main "$1"; mkdir -p "$1/_types" "$1/books"; printf 'spec_version: "0.3.0"\n' > "$1/mdbase.yaml"; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {status: {enum: [open, done]}}}}\n---\n' > "$1/_types/book.md"; }
narrow5() { perl -pi -e 's/enum: \[open, done\]/enum: [done]/' "$1/_types/book.md"; git -C "$1" add _types/book.md; }
commit5() { git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null commit -q -m i; }
R5=$Z/r5a; mk5 $R5; python3 -c "import sys; open(sys.argv[1] + '/books/Café.md','w').write('---\nstatus: open\n---\n')" $R5; commit5 $R5; narrow5 $R5
(cd $R5 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "staged type file: a note with a decomposed-Unicode name is still checked" || bad "NFD note skipped"
R5=$Z/r5b; mk5 $R5; printf -- '---\nstatus: open\n---\n' > $R5/books/g.md; commit5 $R5; mv $R5/books/g.md $Z/r5b-g.md; narrow5 $R5
(cd $R5 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "staged type file: a note deleted on disk but still in the index is checked" || bad "deleted-on-disk note skipped"
R5=$Z/r5c; mk5 $R5; printf -- '---\nstatus: open\n---\n' > $R5/books/g.md; commit5 $R5; ln -s g.md $R5/books/link.md; git -C $R5 add books/link.md
(cd $R5 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "a staged symlinked note does not block the commit" || bad "symlink note blocks"
printf -- '---\nstatus: nope\n---\n' > $R5/books/ita.md; git -C $R5 add -N books/ita.md; printf '\n' >> $R5/_types/book.md; git -C $R5 add _types/book.md
(cd $R5 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "an intent-to-add entry is not checked as an empty note" || bad "intent-to-add reported"
R5=$Z/r5d; mk5 $R5; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {meta: {type: object, required: [isbn]}}}}\n---\n' > $R5/_types/book.md; printf -- '---\nmeta: {pages: 3}\n---\n' > $R5/books/n.md
$RS check $R5/books/n.md 2>&1 | grep -q "meta/isbn" && ok "a missing nested required field is named with its path" || bad "nested required named as top level"
R5=$Z/r5e; mk5 $R5; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "books/*.md"}\ncommon: &c {title: {type: string}}\nschema: {value: {type: object, properties: {<<: *c}}}\n---\n' > $R5/_types/book.md; printf -- '---\ntitle: a\n---\n' > $R5/books/n.md
$RS check $R5/books/n.md 2>&1 | grep -q "merge keys" && ok "a YAML merge key in a type file is reported clearly" || bad "merge key message"
for g in '{books,films}/*.md' '/books/*.md' './books/*.md'; do R5=$Z/r5g$RANDOM; mk5 $R5; perl -pi -e "s#books/\\*\\.md#$g#" $R5/_types/book.md; printf -- '---\nstatus: nope\n---\n' > $R5/books/n.md; $RS check $R5/books/n.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "unsupported glob $g is reported, not silently matching nothing" || bad "glob $g silent"; done
R5=$Z/r5h; mk5 $R5; for i in 1 2 3; do printf -- '---\nstatus: open\n---\n' > $R5/books/n$i.md; done; mkdir -p $R5/ro; chmod 555 $R5/ro; out=$($RS init $R5/books --out $R5/ro/x.md 2>&1); rc=$?; chmod 755 $R5/ro; [ $rc -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && ok "init into an unwritable folder exits 2, no traceback" || bad "init unwritable rc=$rc $out"
LW=$Z/lw; git init -q $LW; printf '#!/bin/sh\n# migrated away from lefthook last year\necho ok\n' > $LW/.git/hooks/pre-commit; $RS install-git-hook $LW >/dev/null 2>&1; [ $? -eq 0 ] && grep -q "check --staged" $LW/.git/hooks/pre-commit && ok "the word lefthook in a comment does not count as lefthook" || bad "lefthook word refused"
EH=$Z/eh; git init -q $EH; : > $EH/.git/hooks/pre-commit; $RS install-git-hook $EH >/dev/null 2>&1; [ $? -eq 0 ] && head -1 $EH/.git/hooks/pre-commit | grep -q '^#!' && ok "an empty existing hook is replaced by a fresh one" || bad "empty hook refused"
CV=$Z/cv; mkdir -p $CV/_types $CV/t; printf 'spec_version: "0.3.0"\n' > $CV/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: t\nmatch: {path_glob: "t/*.md"}\nx-record-schema:\n  awaiting_human: {field: s, values: [3]}\nschema: {value: {type: object}}\n---\n' > $CV/_types/t.md; printf -- '---\ns: 3\n---\n' > $CV/t/a.md; printf -- '---\ns: "3"\n---\n' > $CV/t/b.md
out=$($RS count --json $CV/t 2>&1); printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["awaiting"]==1 and d["by_value"]=={"3":1,"\"3\"":1}, d' && ok "count keeps the string \"3\" apart from the number 3" || bad "count merges types: $out"
$RS check $CV/_types >/dev/null 2>&1; [ $? -eq 2 ] && ok "check of the _types folder exits 2 (a folder)" || bad "check _types folder"

echo "regressions, correctness review round 6:"
V6=$Z/v6; mkdir -p $V6/.obsidian $V6/db; printf 'spec_version: "0.3.0"\n' > $V6/db/mdbase.yaml
python3 -c "print('views: ' + '['*5000 + ']'*5000)" > $V6/db/deep.base; out=$($RS base-check $V6/db/deep.base 2>&1); ! printf '%s' "$out" | grep -q Traceback && ok "a deeply nested .base is a problem line, not a traceback" || bad "deep .base traceback"
printf 'views:\n  - name: A\nx: !!timestamp 2024-99-99\n' > $V6/db/ts.base; out=$($RS base-check $V6/db/ts.base 2>&1); [ $? -eq 1 ] && ! printf '%s' "$out" | grep -q Traceback && ok "a bad explicit tag in a .base is a problem line" || bad "bad tag .base: $out"
printf 'views:\n  - name: A\nviews:\n  - name: B\n' > $V6/db/dup.base; $RS base-check $V6/db/dup.base 2>&1 | grep -q "duplicate key" && ok "duplicate keys in a .base are refused" || bad ".base duplicate keys"
B6=$Z/b6; mkdir -p "$B6/notes{2024}"; printf 'spec_version: "0.3.0"\n' > $B6/mdbase.yaml; for i in 1 2 3; do printf -- '---\ns: a\n---\n' > "$B6/notes{2024}/n$i.md"; done
$RS init "$B6/notes{2024}" >/dev/null 2>&1 && $RS check "$B6/notes{2024}"/n1.md >/dev/null 2>&1 && ok "init escapes a brace in a folder name and the draft applies" || bad "brace folder name"
T6=$Z/t6; mkdir -p $T6/docs; printf 'spec_version: "0.3.0"\n' > $T6/mdbase.yaml; for i in 1 2 3; do printf -- '---\ntype: TEMPLATE\ns: a\n---\n' > $T6/docs/n$i.md; done; $RS init $T6/docs >/dev/null 2>&1; [ -f $T6/_types/docs.md ] && ok "init never names a draft TEMPLATE or README" || bad "init named the draft TEMPLATE"
S6=$Z/s6; mk5 $S6; perl -pi -e 's/enum: \[open, done\]/enum: [done]/' $S6/_types/book.md; printf -- '---\nstatus: open\n---\n' > $S6/books/a.md; git -C $S6 add -A; mv $S6/_types/book.md $Z/s6-book.md
(cd $S6 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a type file staged but deleted on disk is still applied" || bad "staged type file deleted on disk ignored"
U6=$Z/u6; mk5 $U6; perl -pi -e 's/enum: \[open, done\]/enum: [done]/' $U6/_types/book.md; commit5 $U6; perl -pi -e 's/enum: \[done\]/enum: [open, done]/' $U6/_types/book.md; printf -- '---\nstatus: open\n---\n' > $U6/books/a.md; git -C $U6 add books/a.md
(cd $U6 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "an unstaged loosening of a type file does not let a bad note into the commit" || bad "unstaged type edit overrode the index"
W6=$Z/w6/.claude/worktrees/agent1; mk5 $W6; printf -- '---\nstatus: nope\n---\n' > $W6/books/a.md; $RS check $W6/books/a.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a collection inside .claude/worktrees is checked" || bad "worktree collection skipped"
mkdir -p $W6/books/.trash; printf -- '---\nstatus: nope\n---\n' > $W6/books/.trash/a.md; $RS check $W6/books/.trash/a.md >/dev/null 2>&1 && ok "a hidden folder inside a collection is still skipped" || bad "hidden folder inside collection checked"
D6=$Z/d6; mk5 $D6; perl -pi -e 's#books/\*\.md#books/**/*.md#' $D6/_types/book.md; mkdir -p $D6/books/a/b/c; printf -- '---\nstatus: nope\n---\n' > $D6/books/a/b/c/p.md; $RS check $D6/books/a/b/c/p.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a ** glob reaches a note four folders down" || bad "deep ** note skipped"
R6=$Z/r6; mk5 $R6; mkdir -p $R6/books/sub; printf -- '---\nstatus: nope\n---\n' > $R6/books/a.md; git -C $R6 add -A; git -C $R6 config diff.relative true
(cd $R6/books/sub && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "check --staged from a subfolder with diff.relative=true still sees staged notes" || bad "diff.relative hides staged notes"
E6=$Z/e6; git init -q $E6; : > $E6/.git/hooks/pre-commit; chmod 644 $E6/.git/hooks/pre-commit; $RS install-git-hook $E6 >/dev/null 2>&1; [ -x $E6/.git/hooks/pre-commit ] && ok "an empty non-executable hook is replaced by an executable one" || bad "empty hook left non-executable"
printf '{}' | $RS hook --bogus >/dev/null 2>&1; a=$?; printf '{}' | $RS hook --max-lines abc >/dev/null 2>&1; [ $a -eq 0 ] && [ $? -eq 0 ] && ok "hook exits 0 even with bad arguments" || bad "hook bad arguments exit code"

echo "regressions, README cold read round 7:"
W7=$Z/w7/.claude/worktrees/a; mkdir -p $W7/.obsidian $W7/db; printf 'views:\n  - type: table\n    name: A\nfilters:\n  and: x\n' > $W7/db/v.base
$RS base-check $W7/db/v.base >/dev/null 2>&1; [ $? -eq 1 ] && ok "a Base in a vault inside .claude/worktrees is checked" || bad "worktree Base skipped"
mkdir -p $W7/.trash; cp $W7/db/v.base $W7/.trash/v.base; $RS base-check $W7/.trash/v.base >/dev/null 2>&1 && ok "a Base in a hidden folder inside the vault is still skipped" || bad "hidden Base inside vault checked"

echo "regressions, correctness review round 7:"
I7=$Z/i7; mk5 $I7; printf -- '---\nstatus: open\n---\n' > $I7/books/a.md; commit5 $I7; printf -- '---\nkind: mdbase.type\nname: d\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, required: [isbn]}}\n---\n' > $I7/_types/draft.md; printf -- '---\nstatus: done\n---\n' > $I7/books/a.md; git -C $I7 add books/a.md
(cd $I7 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "an untracked draft type file does not refuse a commit (not in the commit)" || bad "untracked draft applied"
git -C $I7 rm -q --cached _types/book.md; printf -- '---\nstatus: anything\n---\n' > $I7/books/a.md; git -C $I7 add books/a.md
(cd $I7 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "a type file removed from the index no longer applies" || bad "git rm --cached type file still applied"
M7=$Z/m7; mk5 $M7; printf -- '---\nstatus: open\n---\n' > $M7/books/a.md; commit5 $M7; mv $M7/mdbase.yaml $Z/m7-marker; printf -- '---\nstatus: WRONG\n---\n' > $M7/books/a.md; git -C $M7 add books/a.md
(cd $M7 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "the collection marker is read from the index under --staged" || bad "marker read from disk"
N7=$Z/n7; mk5 $N7; python3 -c "import sys,unicodedata; open(sys.argv[1]+'/_types/'+unicodedata.normalize('NFD','café')+'.md','w').write(open(sys.argv[1]+'/_types/book.md').read().replace('name: book','name: cafe'))" $N7; printf -- '---\nstatus: open\n---\n' > $N7/books/a.md; commit5 $N7
python3 -c "import sys,os,unicodedata; p=sys.argv[1]+'/_types/'+unicodedata.normalize('NFD','café')+'.md'; open(p,'w').write(open(p).read().replace('enum: [open, done]','type: strng'))" $N7; printf -- '---\nstatus: done\n---\n' > $N7/books/a.md; git -C $N7 add books/a.md
(cd $N7 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "an unstaged edit to a decomposed-Unicode type file does not change the result" || bad "NFD type file read from disk"
P7=$Z/p7; mk5 $P7; for i in $(seq 1 400); do printf -- '---\nstatus: open\n---\n' > $P7/books/n$i.md; done; git -C $P7 add -A; s0=$(date +%s); (cd $P7 && $OLDPWD/$RS check --staged >/dev/null 2>&1); s1=$(date +%s); [ $((s1 - s0)) -lt 20 ] && ok "check --staged on 400 new notes is quick ($((s1 - s0)) s)" || bad "check --staged slow: $((s1 - s0)) s"

echo "regressions, correctness review round 8:"
mkc8() { mkdir -p "$1/_types" "$1/books"; printf 'spec_version: "0.3.0"\n' > "$1/mdbase.yaml"; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {status: {enum: [open, done]}}}}\n---\n' > "$1/_types/book.md"; }
G8=$Z/g8main; git init -q $G8; mkc8 $G8/sub/coll; printf -- '---\nstatus: done\n---\n' > $G8/sub/coll/books/a.md; commit5 $G8; $RS install-git-hook $G8 >/dev/null 2>&1
git -C $G8 worktree add -q $Z/g8wt -b w1 2>/dev/null; printf -- '---\nstatus: BAD\n---\n' > $Z/g8wt/sub/coll/books/a.md; git -C $Z/g8wt add -A
(cd $Z/g8wt && git -c user.email=t@t -c user.name=t commit -q -m bad >/dev/null 2>&1); [ $? -ne 0 ] && ok "the commit gate refuses a bad note in a linked worktree (collection below the top)" || bad "worktree commit let a bad note through"
(cd $Z/g8wt && GIT_DIR=$(git rev-parse --absolute-git-dir) $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "check --staged with GIT_DIR exported still finds the type files" || bad "GIT_DIR hides type files"
L8=$Z/l8; mk5 $L8; mkdir -p $L8/shared; printf -- '---\nstatus: open\n---\n' > $L8/books/a.md; commit5 $L8; mv $L8/_types/book.md $L8/shared/book.md; ln -s ../shared/book.md $L8/_types/book.md; printf -- '---\nstatus: BAD\n---\n' > $L8/books/a.md; git -C $L8 add -A
(cd $L8 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a symlinked type file applies under --staged" || bad "symlinked type file ignored under --staged"
Y8=$Z/y8; mk5 $Y8; mv $Y8/mdbase.yaml $Y8/shared.yaml; ln -s shared.yaml $Y8/mdbase.yaml; printf -- '---\nstatus: BAD\n---\n' > $Y8/books/a.md; git -C $Y8 add -A
(cd $Y8 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a symlinked mdbase.yaml marks the collection under --staged" || bad "symlinked marker ignored"
K8=$Z/k8; mk5 $K8; printf -- '---\nstatus: open\n---\n' > $K8/real.md; ln -s ../real.md $K8/books/a.md; commit5 $K8; rm $K8/books/a.md; printf -- '---\nstatus: BAD\n---\n' > $K8/books/a.md; git -C $K8 add -A
(cd $K8 && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a symlink replaced by a bad note (type change) is checked" || bad "type change unchecked"

BT=$Z/bt8; mkdir -p $BT/_types; printf 'spec_version: "0.3.0"\n' > $BT/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: b\nmatch: {path_glob: "b/*.md"}\nschema: {value: {type: strng}}\n---\n' > $BT/_types/b.md
$RS check $BT/_types/b.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a broken type file is reported even when its collection has no notes" || bad "broken type file with no notes passes"
MG=$Z/mg8; mk5 $MG; printf -- '---\nstatus: done\n---\n' > $MG/books/a.md; commit5 $MG; $RS install-git-hook $MG >/dev/null 2>&1; [ -x $MG/.git/hooks/pre-merge-commit ] && grep -q "check --staged" $MG/.git/hooks/pre-merge-commit && ok "install-git-hook also installs pre-merge-commit" || bad "no pre-merge-commit hook"
git -C $MG checkout -q -b tighten; perl -pi -e 's/enum: \[open, done\]/enum: [open]/' $MG/_types/book.md; git -C $MG -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null commit -qam t; git -C $MG checkout -q main; printf -- '---\nstatus: done\n---\n' > $MG/books/b.md; git -C $MG add -A; git -C $MG -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null commit -qm b
(cd $MG && git -c user.email=t@t -c user.name=t merge -q --no-edit tighten >/dev/null 2>&1); [ $? -ne 0 ] && ok "a merge that brings in a bad note is refused" || bad "merge let a bad note in"
RM=$Z/rm8; mkdir -p $RM/README; printf 'spec_version: "0.3.0"\n' > $RM/mdbase.yaml; for i in 1 2 3; do printf -- '---\ns: a\n---\n' > $RM/README/n$i.md; done; $RS init $RM/README >/dev/null 2>&1; [ -f $RM/_types/readme-notes.md ] && ok "init on a folder named README writes a type file that applies" || bad "init README folder"
HV=$(mktemp -d)/hv8/.claude/w/db; mkdir -p $HV; for i in 1 2 3; do printf -- '---\ns: a\n---\n' > $HV/n$i.md; done; out=$($RS init $HV 2>&1); printf '%s' "$out" | grep -q "no mdbase.yaml" && ok "init under a hidden folder with no marker gives the right reason" || bad "init hidden folder reason: $out"
DQ='/my$HOME dir'; QD="$Z/q8$DQ"; mkdir -p "$QD"; cp frontmatter_schema_check.py "$QD/"; QR=$Z/qr8; mk5 $QR; python3 "$QD/frontmatter_schema_check.py" install-git-hook $QR >/dev/null 2>&1; grep -q 'my$HOME dir' $QR/.git/hooks/pre-commit && sh -n $QR/.git/hooks/pre-commit && ok "the installed line quotes paths that contain \$" || bad "unquoted \$ path in hook line"
HK=$Z/hk8; git init -q $HK; git -C $HK config core.hooksPath .husky/_; $RS install-git-hook $HK >/dev/null 2>&1; [ $? -eq 2 ] && [ ! -e $HK/.husky ] && ok "a husky refusal creates no folder" || bad "husky refusal created .husky"
$RS init $W/db --out '' >/dev/null 2>&1; [ $? -eq 64 ] && ok "init --out with an empty value exits 64" || bad "init --out empty"

echo "regressions, README cold read round 9:"
PM=$Z/pm9; mk5 $PM; ln -s /dev/null $PM/.git/hooks/pre-merge-commit; $RS install-git-hook $PM >/dev/null 2>&1; rc=$?; [ $rc -eq 2 ] && [ ! -e $PM/.git/hooks/pre-commit ] && ok "a refused pre-merge-commit hook refuses the whole install and writes nothing" || bad "pre-merge-commit refusal rc=$rc"

echo "regressions, correctness review round 9:"
SL=$Z/sl9; mk5 $SL; mkdir -p $SL/shared; mv $SL/_types/book.md $SL/shared/book.md; ln -s ../shared/book.md $SL/_types/book.md; printf -- '---\nstatus: open\n---\n' > $SL/books/a.md; commit5 $SL
perl -pi -e 's/enum: \[open, done\]/enum: [open, done, wrong]/' $SL/shared/book.md; printf -- '---\nstatus: wrong\n---\n' > $SL/books/b.md; git -C $SL add books/b.md
(cd $SL && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a symlinked type file is read from the index, not through the link on disk" || bad "symlinked type file read from disk"
git -C $SL checkout -q -- shared/book.md; git -C $SL reset -q books/b.md; perl -pi -e 's/enum: \[open, done\]/enum: [done]/' $SL/shared/book.md; git -C $SL add shared/book.md
(cd $SL && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "staging the target of a type-file symlink re-checks its collection" || bad "staged link target ignored"
MK=$Z/mk9; git init -q -b main $MK; mkdir -p $MK/c/_types $MK/c/books; printf -- '---\nkind: mdbase.type\nname: b\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {s: {enum: [ok]}}}}\n---\n' > $MK/c/_types/b.md; printf -- '---\ns: bad\n---\n' > $MK/c/books/a.md; commit5 $MK; printf 'spec_version: "0.3.0"\n' > $MK/c/mdbase.yaml; git -C $MK add c/mdbase.yaml
(cd $MK && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 1 ] && ok "a staged mdbase.yaml checks every note in its new collection" || bad "staged marker alone validates nothing"
PS=$Z/ps9; git init -q -b main $PS; for c in 'st*' stx; do mkdir -p "$PS/$c/_types" "$PS/$c/books"; printf 'spec_version: "0.3.0"\n' > "$PS/$c/mdbase.yaml"; printf -- '---\nkind: mdbase.type\nname: b\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {status: {enum: [ok]}}}}\n---\n' > "$PS/$c/_types/b.md"; done; printf -- '---\nstatus: wrong\n---\n' > $PS/stx/books/legacy.md; commit5 $PS; printf '\n' >> "$PS/st*/_types/b.md"; git -C $PS add "st*/_types/b.md"
(cd $PS && $OLDPWD/$RS check --staged >/dev/null 2>&1); [ $? -eq 0 ] && ok "a folder name with * is a literal path to git, not a pattern" || bad "pathspec magic pulled in another collection"
$RS base-check --staged x.base >/dev/null 2>&1; [ $? -eq 64 ] && ok "an option given to the wrong command exits 64" || bad "base-check --staged exit code"

echo "regressions, README cold read round 10:"
OLDPY=$(command -v python3.10 || (command -v uv >/dev/null && uv python find 3.10 2>/dev/null) || true)
if [ -n "$OLDPY" ]; then "$OLDPY" -c "import ast; ast.parse(open('frontmatter_schema_check.py').read())" && ok "the module parses on Python 3.10, the oldest supported" || bad "the module does not parse on Python 3.10"
else echo "  skip Python 3.10 parse (no python3.10 or uv)"; fi

echo "regressions, correctness review round 10:"
st10() { (cd "$1" && $OLDPWD/$RS check --staged >/dev/null 2>&1); }
A=$Z/a10; mk5 $A; mv $A/_types $A/shared_types; ln -s shared_types $A/_types; printf -- '---\nstatus: open\n---\n' > $A/books/a.md; commit5 $A; printf -- '---\nstatus: BAD\n---\n' > $A/books/b.md; git -C $A add books/b.md
st10 $A; [ $? -eq 1 ] && ok "a symlinked _types folder fails closed at commit time" || bad "symlinked _types folder passed"
B=$Z/b10; mk5 $B; mkdir -p $B/shared; cp $B/_types/book.md $B/shared/loose.md; perl -pe 's/enum: \[open, done\]/enum: [done]/' $B/_types/book.md > $B/shared/strict.md; mv $B/_types/book.md $Z/b10-orig.md; ln -s ../shared/loose.md $B/_types/book.md; printf -- '---\nstatus: open\n---\n' > $B/books/a.md; commit5 $B; ln -sfn ../shared/strict.md $B/_types/book.md; git -C $B add _types/book.md
st10 $B; [ $? -eq 1 ] && ok "retargeting a type-file symlink is caught at commit time" || bad "retargeted type-file link passed"
C=$Z/c10; git init -q -b main $C; mkdir -p $C/c/_types $C/c/books; printf -- '---\nkind: mdbase.type\nname: b\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {s: {enum: [ok]}}}}\n---\n' > $C/c/_types/b.md; printf -- '---\ns: bad\n---\n' > $C/c/books/a.md; printf 'spec_version: "0.3.0"\n' > $C/marker.yaml; commit5 $C; ln -s ../marker.yaml $C/c/mdbase.yaml; git -C $C add c/mdbase.yaml
st10 $C; [ $? -eq 1 ] && ok "a newly staged symlinked mdbase.yaml checks its collection" || bad "new marker link validated nothing"
E=$Z/e10; mk5 $E; printf -- '---\nstatus: open\n---\n' > $E/books/a.md; commit5 $E; : > $E/books/empty.md; git -C $E add books/empty.md; printf -- '---\nstatus: open\n---\n' > $E/books/empty.md
st10 $E; [ $? -eq 1 ] && ok "a staged empty note is not mistaken for intent-to-add" || bad "empty staged note skipped"
N=$Z/n10; git init -q -b main $N; printf 'x\n' > $N/mdbase.yaml; mkdir -p $N/_types $N/inner; printf -- '---\nkind: mdbase.type\nname: all\nmatch: {path_glob: "**/*.md"}\nschema: {value: {type: object, required: [title]}}\n---\n' > $N/_types/all.md; printf 'x\n' > $N/inner/mdbase.yaml; printf -- '---\nfoo: 1\n---\n' > $N/inner/n.md; commit5 $N; git -C $N rm -q inner/mdbase.yaml
st10 $N; [ $? -eq 1 ] && ok "deleting a nested mdbase.yaml re-checks the collection that inherits its notes" || bad "nested marker deletion unchecked"
D=$Z/d10; mkdir -p $D/_types $D/notes; printf 'x\n' > $D/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: task\nschema:\n  value: {type: object, properties: {status: {enum: [open, done]}}}\n---\n' > $D/_types/task.md; printf -- '---\ntype: task\nstatus: open\nstatus: done\n---\n' > $D/notes/dup.md
$RS check $D/notes/dup.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a duplicate key in a note typed by its own type: field is reported" || bad "dup key in type:-selected note passed"
S10=$Z/s10; mk5 $S10; mkdir -p $S10/books/sub/_types; perl -pi -e 's#books/\*\.md#books/**/*.md#' $S10/_types/book.md; printf -- '---\nstatus: BAD\n---\n' > $S10/books/sub/_types/x.md
$RS check $S10/_types/book.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "check <type file> reaches a note in a nested folder named _types" || bad "nested _types folder skipped"
I10=$Z/i10; git init -q -b main $I10; mkdir -p $I10/.git/hooks/pre-merge-commit; out=$($RS install-git-hook $I10 2>&1); rc=$?; [ $rc -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && [ ! -e $I10/.git/hooks/pre-commit ] && ok "a pre-merge-commit that is a folder refuses the install cleanly" || bad "install crash rc=$rc"
$RS check $S10/_types/nonexistent.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "check of a missing type file reports no such file" || bad "missing type file silent"

echo "regressions, correctness review round 11:"
R11=$Z/r11; mk5 $R11; printf -- '---\nkind: mdbase.type\nname: anote\nmatch: {path_glob: "a/*.md"}\nschema:\n  value: {type: object, required: [status], properties: {status: {enum: [open]}}}\n---\n' > $R11/_types/anote.md; mkdir -p $R11/a; printf 'spec_version: "0.3.0"\n' > $R11/a/mdbase.yaml; printf -- '---\nstatus: bad\n---\n' > $R11/a/n.md; commit5 $R11; git -C $R11 mv a/mdbase.yaml a/mdbase.yaml.bak
st10 $R11; [ $? -eq 1 ] && ok "renaming a nested mdbase.yaml away re-checks the notes it leaves" || bad "renamed marker unchecked"
T11=$Z/t11; git init -q -b main $T11; mkdir -p $T11/_types $T11/books; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "books/*.md"}\nschema: {value: {type: object, properties: {status: {enum: [open]}}}}\n---\n' > $T11/_types/book.md; printf -- '---\nstatus: bad\n---\n' > $T11/books/a.md; printf 'spec_version: "0.3.0"\n' > $T11/mdbase.yaml; git -C $T11 add _types books; git -C $T11 add -N mdbase.yaml
st10 $T11; [ $? -eq 0 ] && ok "an intent-to-add mdbase.yaml does not count at commit time" || bad "intent-to-add marker counted"
H11=$Z/h11; git init -q -b main $H11; printf x > $H11/hkfile; git -C $H11 config core.hooksPath hkfile; out=$($RS install-git-hook $H11 2>&1); rc=$?; [ $rc -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && ok "a hooks path that cannot be created refuses with exit 2" || bad "hooks folder creation rc=$rc"
U11=$Z/u11; mk5 $U11; printf -- '---\nstatus: bad\n---\n' > $U11/books/x.md; chmod 000 $U11/_types; $RS check $U11/books/x.md >/dev/null 2>&1; rc=$?; chmod 755 $U11/_types; [ $rc -eq 1 ] && ok "an unreadable _types folder is a problem, not a silent pass" || bad "unreadable _types passed"
M11=$Z/m11; mk5 $M11; perl -pi -e 's/^---$/--- / if $. == 1' $M11/_types/book.md; $RS check $M11/_types/book.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "naming a malformed type file reports it" || bad "malformed named type file silent"
Q11=$Z/q11; mkdir -p $Q11/_types $Q11/n; printf 'x\n' > $Q11/mdbase.yaml; printf -- "---\nkind: mdbase.type\nname: q\nmatch: {path_glob: \"n/*.md\"}\nschema: {value: {type: object, required: [\"it's\"]}}\n---\n" > $Q11/_types/q.md; printf -- '---\na: 1\n---\n' > $Q11/n/a.md
$RS check $Q11/n/a.md 2>&1 | grep -q "it's" && ok "a required field whose name holds an apostrophe is named exactly" || bad "apostrophe field name mangled"

echo "regressions, correctness review round 12:"
S12=$Z/s12; git init -q -b main --object-format=sha256 $S12 2>/dev/null && { mk5x() { mkdir -p "$1/_types" "$1/books"; printf 'spec_version: "0.3.0"\n' > "$1/mdbase.yaml"; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "**/*.md"}\nschema: {value: {type: object, properties: {status: {enum: [open, done]}}}}\n---\n' > "$1/_types/book.md"; }; mk5x $S12; commit5 $S12; mkdir -p $S12/sub; printf -- '---\nstatus: bad\n---\n' > $S12/sub/b.md; git -C $S12 add sub/b.md; : > $S12/sub/mdbase.yaml; git -C $S12 add -N sub/mdbase.yaml
st10 $S12; [ $? -eq 1 ] && ok "intent-to-add is recognised in a SHA-256 repository" || bad "SHA-256 intent-to-add marker counted"; }
D12=$Z/d12; mk5 $D12; printf -- '---\nstatus: open\n---\n' > $D12/books/a.md; commit5 $D12; printf '# design notes\n' > $D12/_types/design-notes.md; mkdir -p $D12/_types/.hidden; printf 'x\n' > $D12/_types/.hidden/x.md; ln -s design-notes.md $D12/_types/README.md; git -C $D12 add -A
st10 $D12; [ $? -eq 0 ] && ok "documentation, hidden files and a README link under _types do not refuse a commit" || bad "documentation under _types refused"
$RS check $D12/_types/design-notes.md >/dev/null 2>&1; [ $? -eq 0 ] && ok "naming a documentation file under _types is a note, not a failure" || bad "documentation file failed check"
L12=$Z/l12; mk5 $L12; mkdir -p $L12/shared $L12/strict; printf -- '---\nkind: mdbase.type\nname: strict\nmatch: {path_glob: "strict/*.md"}\nschema: {value: {type: object, required: [title]}}\n---\n' > $L12/shared/strict.md; ln -s ../shared $L12/_types/shared; printf -- '---\nx: 1\n---\n' > $L12/strict/a.md
$RS check $L12/strict/a.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a symlinked _types subfolder is not silently ignored on disk" || bad "symlinked _types subfolder ignored"
K12=$Z/k12; mk5 $K12; mkdir -p $Z/k12real; mv $K12/_types/book.md $Z/k12real/; rmdir $K12/_types; ln -s ../k12real $K12/_types; printf -- '---\nkind: mdbase.type\nname: x\nschema: 3\n---\n' > $K12/_types/broken.md
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$K12/_types/broken.md" | $RS hook); printf "%s" "$out" | grep -q "does not load" && ok "the hook reports a type file written through a symlinked _types folder" || bad "hook silent through _types link: $out"
U12=$Z/u12; mkdir -p $U12/_types; printf 'x\n' > $U12/mdbase.yaml; G=$(python3 -c "import unicodedata; print(unicodedata.normalize('NFD','café'))"); F=$(python3 -c "import unicodedata; print(unicodedata.normalize('NFC','café'))"); printf -- "---\nkind: mdbase.type\nname: c\nmatch: {path_glob: \"$G/*.md\"}\nschema: {value: {type: object, required: [title]}}\n---\n" > $U12/_types/c.md; mkdir -p "$U12/$F"; printf -- '---\nx: 1\n---\n' > "$U12/$F/n.md"
$RS check "$U12/$F/n.md" >/dev/null 2>&1; [ $? -eq 1 ] && ok "a decomposed-Unicode glob matches a composed folder name" || bad "NFD glob missed NFC folder"
V12=$Z/v12; mk5 $V12; perl -pi -e 's/schema: \{value: \{type: object,/schema: {value: {type: object, additionalProperties: false,/' $V12/_types/book.md; printf -- '---\nstatus: open\n"\\ud800x": 1\n---\n' > $V12/books/s.md; out=$($RS check $V12/books/s.md 2>&1); ! printf '%s' "$out" | grep -q Traceback && ok "a lone surrogate in a field name prints without a traceback" || bad "surrogate traceback"

echo "regressions, correctness review round 13:"
Y13=$Z/y13; git init -q -b main $Y13; mkdir -p $Y13/_types $Y13/n $Y13/real; printf 'x\n' > $Y13/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: m\nmatch: {path_glob: "n/*.md"}\nschema: {value: {type: object, required: [zz]}}\n---\n' > $Y13/real/m.md; ln -s ../real $Y13/_types/linked; printf -- '---\na: 1\n---\n' > $Y13/n/ok.md; git -C $Y13 add -A
st10 $Y13; [ $? -eq 1 ] && ok "a symlinked folder inside _types is refused at commit time" || bad "symlinked _types subfolder passed the commit"
$RS check $Y13/n/ok.md >/dev/null 2>&1; [ $? -eq 1 ] && ok "a symlinked folder inside _types is an error on disk too" || bad "disk ignores symlinked subfolder"
W13=$Z/w13; mk5 $W13; printf -- '---\nstatus: open\n---\n' > $W13/books/a.md; commit5 $W13; printf '# Adding a type\n\n```\nkind: mdbase.type\nname: x\n```\n' > $W13/_types/HOWTO.md; printf '# guide\n' > $W13/guide.md; ln -s ../guide.md $W13/_types/glink.md; git -C $W13 add -A
st10 $W13; [ $? -eq 0 ] && ok "a how-to under _types that quotes a type file, and a link to documentation, do not refuse a commit" || bad "documentation under _types refused"
$RS check $W13/books/a.md >/dev/null 2>&1; [ $? -eq 0 ] && ok "a how-to quoting kind: mdbase.type does not break the collection" || bad "how-to broke the collection"
printf '{}' | $RS --max-lines x hook >/dev/null 2>&1; [ $? -eq 0 ] && ok "the hook exits 0 with options before it" || bad "hook options first exit code"

echo "regressions, correctness review round 15:"
X15=$Z/x15; mkdir -p $X15/_types $X15/notes $X15/ext; printf 'x\n' > $X15/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: task\nmatch: {path_glob: "notes/*.md"}\nschema: {value: {type: object, required: [owner]}}\n---\n' > $X15/ext/task.md; ln -s ../ext/task.md $X15/_types/task.md; printf -- '---\nstatus: open\n---\n' > $X15/notes/a.md
$RS check $X15/notes/a.md 2>&1 | grep -q "is a symlink" && ok "on disk, a symlinked type file is reported, as at commit time" || bad "disk followed a symlinked type file"
Y15=$Z/y15; mkdir -p $Y15/notes $Y15/ext; printf 'x\n' > $Y15/mdbase.yaml; cp $X15/ext/task.md $Y15/ext/; ln -s ext $Y15/_types; printf -- '---\nstatus: open\n---\n' > $Y15/notes/a.md
$RS check $Y15/notes/a.md 2>&1 | grep -q "is a symlink" && ok "on disk, a symlinked _types is reported" || bad "disk followed a symlinked _types"
V15=$Z/v15; mkdir -p $V15/.obsidian $V15/_types $V15/Books $V15/Events; printf 'x\n' > $V15/mdbase.yaml; printf -- '---\nkind: mdbase.type\nname: book\nmatch: {path_glob: "Books/*.md"}\nschema: {value: {type: object}}\n---\n' > $V15/_types/book.md; for i in 1 2 3; do printf -- '---\nwhen: x\n---\n' > $V15/Events/e$i.md; done; printf 'views:\n  - type: table\n    name: All\n    order: [file.name]\n' > $V15/Events/Events.base
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$V15/Events/Events.base" | $RS hook); printf '%s' "$out" | grep -q "no type file covers" && ok "a Base in an uncovered folder inside a collection gets the init hint" || bad "no init hint inside a collection: $out"
G15=$Z/g15; mk5 $G15; mkdir -p $G15/misc; printf -- '---\ntype: boook\nstatus: x\n---\n' > $G15/misc/g.md
out=$($RS check $G15/misc/g.md 2>&1); [ $? -eq 0 ] && [ -z "$out" ] && ok "a type: that names no type file is an ordinary field (silent pass)" || bad "unknown type: not silent: $out"

echo; [ $fail -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }

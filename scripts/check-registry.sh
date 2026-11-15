#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Registry integrity gate. Proves that the committed registry is one coherent
# artefact, from the hand-edited seed to the generated JSON the Worker serves.
#
#   1. The seed deed (verisim/seed/chora-registry_praxis.deed) parses to
#      exactly `:total-repos` rows, with unique names, and its scheme clade-12
#      names the categories of clades.json.
#   2. worker/data/{repos,clades,index}.json are valid JSON.
#   3. worker/data is NOT stale: a fresh export into a scratch directory is
#      byte-identical (index.json compared without its `generated` stamp).
#   4. Counts agree across seed, repos.json and index.json.
#   5. Identity, for every entry: `uuid` is the ADR-008 profile C UUIDv8 of
#      `github.com/<owner>/<name>` at the repo's RECORDED BIRTH PATH, not its
#      current path (ADR 0008: an id is minted once and never changes), in the
#      domain that minted it (`minted_in`: gv-clade-index before V9,
#      chora-registry after), and equals the id the seed stores. The birth
#      path is the archive's `birth` for a moved or renamed repo, else the
#      current `github`. Ids are unique. No UUIDv5 and none of the fields
#      retired from /v1 (prefixed, clade, secondary, uuid_v8) are served.
#   6. Archive (ADR 0008): each archive entry names a current repo at its
#      current path and carries that repo's ids; its `birth` is its first
#      `former` path; generations count 1..n with no gap and the current one is
#      n+1; every retired id re-derives from its own path; no current id equals
#      a retired id or another repo's id, so a vacated path's id is never minted
#      for a new repo; and no archive data reaches repos.json or index.json,
#      the files that are served.
#   7. Nothing registered is lost (ADR 0008, owner decision of 2026-11-12):
#      given the base branch's worker/data/repos.json in GV_BASE_REPOS_JSON,
#      every repo it lists is still listed, followed by its v8 id (a base
#      from before the /v1 reset carries it as `uuid_v8`), with that id.
#      A deleted repository stays in the seed with its status; it is never
#      removed, so its ids stay checked against every new entry. Skipped,
#      with a notice, when no base is given (a local run).
#
# Exit 0 only when every check passes. Never writes inside the repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$ROOT/verisim/seed/chora-registry_praxis.deed"
DATA="$ROOT/worker/data"

# Print the supplied failure message to stderr and terminate the gate with status 1.
fail() { echo "check-registry: FAIL: $*" >&2; exit 1; }
# Require the command named by $1 on PATH, or terminate the gate with status 1.
need() { command -v "$1" >/dev/null 2>&1 || fail "required tool missing: $1"; }
need jq; need uuidgen; need cmp; need bun

# 1. Parse round-trip ------------------------------------------------------
# parse-repos.sh refuses a seed that is not a valid deed of the registry form.
bash "$ROOT/sync/parse-repos.sh" "$SEED" >/dev/null || fail "sync/parse-repos.sh refused the seed"
rows=$(bash "$ROOT/sync/parse-repos.sh" "$SEED" | wc -l | tr -d ' ')
declared=$(bash "$ROOT/sync/parse-repos.sh" "$SEED" --total) || fail "the seed has no :total-repos"
[[ "$rows" = "$declared" ]] || fail "the seed declares :total-repos $declared but parses to $rows rows"
dups=$(bash "$ROOT/sync/parse-repos.sh" "$SEED" | cut -f1 | sort | uniq -d | tr '\n' ' ')
[[ -z "$dups" ]] || fail "duplicate repo names in the seed: $dups"
echo "check-registry: seed parses to $rows rows = :total-repos, names unique"
# The scheme clade-12 in the seed and the clade definitions served from
# clades.a2ml (legacy, still A2ML) name the same categories.
diff <(bash "$ROOT/sync/parse-repos.sh" "$SEED" --categories | sort) \
     <(jq -r '.[] | [.code, .name] | @tsv' "$DATA/clades.json" | sort) >/dev/null \
  || fail "scheme clade-12 in the seed and worker/data/clades.json disagree on the categories"
echo "check-registry: scheme clade-12 holds the same $(jq length "$DATA/clades.json") categories as clades.json"

# 2. JSON validity --------------------------------------------------------
for f in repos clades index archive; do
  [ -f "$DATA/$f.json" ] || fail "$DATA/$f.json is missing"
  jq empty "$DATA/$f.json" 2>/dev/null || fail "$DATA/$f.json is not valid JSON"
done
echo "check-registry: worker/data JSON valid"

# 3. Drift: fresh export must match the committed files -------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
GV_EXPORT_OUT="$scratch" bash "$ROOT/sync/export-json.sh" >/dev/null 2>&1 \
  || fail "sync/export-json.sh failed on the current seed"
for f in repos clades archive; do
  cmp -s "$scratch/$f.json" "$DATA/$f.json" \
    || fail "worker/data/$f.json is stale: run 'bash sync/export-json.sh' and commit the result"
done
if ! diff -q <(jq -S 'del(.generated)' "$scratch/index.json") <(jq -S 'del(.generated)' "$DATA/index.json") >/dev/null; then
  fail "worker/data/index.json is stale: run 'bash sync/export-json.sh' and commit the result"
fi
echo "check-registry: worker/data matches a fresh export (no drift)"

# 4. Counts agree ---------------------------------------------------------
json_repos=$(jq 'length' "$DATA/repos.json")
idx_total=$(jq '.total_repos' "$DATA/index.json")
idx_names=$(jq '.by_name | length' "$DATA/index.json")
[ "$json_repos" = "$rows" ] || fail "repos.json has $json_repos entries, seed has $rows"
[ "$idx_total" = "$rows" ] || fail "index.json total_repos = $idx_total, seed has $rows"
[ "$idx_names" = "$rows" ] || fail "index.json by_name has $idx_names keys, seed has $rows"
echo "check-registry: counts agree ($rows)"

# 5. Identity -------------------------------------------------------------
# An id is minted once, from the birth path, and never changes (ADR 0008, which
# supersedes ADR 0007 and restores the immortal rule of ADR 0006). A move or
# rename changes `github` only. The birth path is not served: it lives in
# archive.json, which records it for every repo that has moved. The served
# `uuid` is the ADR-008 profile C UUIDv8 of the birth path in the domain that
# minted it (`minted_in`, V9); no UUIDv5 is served (ADR 0004 amendment).
jq -r --slurpfile arch "$DATA/archive.json" '
  ($arch[0] | map({key: .name, value: .birth}) | from_entries) as $birth
  | .[] | [.name, ($birth[.name] // .github), (.uuid // ""), (.minted_in // "")] | @tsv' \
  "$DATA/repos.json" > "$scratch/ids.tsv"
bash "$ROOT/sync/parse-repos.sh" "$SEED" --ids > "$scratch/seed-ids.tsv" || fail "sync/parse-repos.sh --ids failed"
jq -r '.[].name' "$DATA/repos.json" | diff - <(cut -f1 "$scratch/seed-ids.tsv") >/dev/null \
  || fail "repos.json and the seed list different repos, or in a different order"
paste <(cut -f2 "$scratch/ids.tsv" | sed 's#/#\t#') <(cut -f3 "$scratch/seed-ids.tsv") \
  | bash "$ROOT/sync/uuid-v8.sh" > "$scratch/v8.txt" || fail "sync/uuid-v8.sh failed"
# The seed stores each repo's v8 id and the domain that minted it (V9): the
# id must be the profile C UUIDv8 of the birth path in that domain.
while IFS=$'\t' read -r name stored domain expect; do
  [[ "$stored" = "$expect" ]] || fail "the seed stores uuid $stored for $name, profile C of its birth path in $domain gives $expect"
done < <(paste "$scratch/seed-ids.tsv" "$scratch/v8.txt")
echo "check-registry: the seed's stored id is the UUIDv8 of the birth path in its minting domain for all $json_repos repos"
# The served uuid and minted_in are the seed's.
while IFS=$'\t' read -r name birth uuid served_domain _ stored domain; do
  [[ "$uuid" = "$stored" ]] || fail "uuid for $name is ${uuid:-<missing>}, the seed stores $stored (profile C of its birth path $birth)"
  [[ "$served_domain" = "$domain" ]] || fail "minted_in for $name is ${served_domain:-<missing>}, the seed records $domain"
done < <(paste "$scratch/ids.tsv" "$scratch/seed-ids.tsv")
echo "check-registry: uuid is the profile C UUIDv8 of the birth path, in its minting domain, for all $json_repos repos"
leak=$(jq -r '[.[] | select(has("uuid_v8") or has("uuid_v5") or has("prefixed") or has("clade") or has("secondary")) | .name] | join(" ")' "$DATA/repos.json")
[[ -z "$leak" ]] || fail "a field retired from /v1 (uuid_v8, uuid_v5, prefixed, clade, secondary) is served: $leak"
dup=$(jq -r '[.[] | {name, id: .uuid}] | group_by(.id) | map(select(length > 1) | map(.name) | join(" = ")) | join("; ")' "$DATA/repos.json")
[[ -z "$dup" ]] || fail "uuid is shared by more than one repo: $dup (an id belongs to one repo; a vacated path's id is never minted again)"
echo "check-registry: uuid is unique across the registry"

# 6. Archive (ADR 0008) ------------------------------------------------------
# For reference only, never served: the earlier paths of each moved repo
# (`former`, oldest first, generation 1 = the birth path) and the ids derived
# for a path and withdrawn (`retired`, the ADR 0007 remints: `uuid` is the v8,
# `uuid_v5` the v5 of that path, kept as record only).
leak=$(jq -r '[.[] | select(has("former") or has("generation") or has("birth") or has("retired")) | .name] | join(" ")' "$DATA/repos.json")
[[ -z "$leak" ]] || fail "archive data reached repos.json (served): $leak"
leak=$(jq -r '[.by_name[] | select(has("former") or has("generation") or has("birth") or has("retired")) | .name] | join(" ")' "$DATA/index.json")
[[ -z "$leak" ]] || fail "archive data reached index.json (served): $leak"
while IFS=$'\t' read -r name github uuid; do
  cur=$(jq -r --arg n "$name" '.[] | select(.name == $n) | [.github, .uuid] | @tsv' "$DATA/repos.json")
  [[ -n "$cur" ]] || fail "archive entry $name is not a current repo"
  IFS=$'\t' read -r cgithub cuuid <<<"$cur"
  [[ "$cgithub" = "$github" ]] || fail "archive entry $name says its current path is $github, repos.json says $cgithub"
  [[ "$cuuid" = "$uuid" ]] || fail "archive entry $name carries id $uuid, repos.json has $cuuid"
done < <(jq -r '.[] | [.name, .github, .uuid] | @tsv' "$DATA/archive.json")
bad=$(jq -r '.[] | select(.birth != (if (.former | length) > 0 then .former[0].github else .github end)) | .name' "$DATA/archive.json" | tr '\n' ' ')
[[ -z "${bad// }" ]] || fail "archive birth must be the first former path (or the current path when none): $bad"
bad=$(jq -r '.[] | select((.former | map(.generation)) != [range(1; (.former | length) + 1)]
                          or .generation != (.former | length) + 1) | .name' "$DATA/archive.json" | tr '\n' ' ')
[[ -z "${bad// }" ]] || fail "archive generations must count 1..n with the current one n+1: $bad"
retired=$(jq '[.[].retired[]] | length' "$DATA/archive.json")
if [[ "$retired" -gt 0 ]]; then
  while IFS=$'\t' read -r name github uuid_v5; do
    expect=$(uuidgen --sha1 --namespace @url --name "github.com/$github")
    [[ "$uuid_v5" = "$expect" ]] || fail "retired uuid_v5 for $name at $github is ${uuid_v5:-<missing>}, UUIDv5 derivation gives $expect"
  done < <(jq -r '.[] | .name as $n | .retired[] | [$n, .github, (.uuid_v5 // "")] | @tsv' "$DATA/archive.json")
  jq -r '.[].retired[] | .github | sub("/"; "\t")' "$DATA/archive.json" \
    | bash "$ROOT/sync/uuid-v8.sh" > "$scratch/retired-v8.txt" || fail "sync/uuid-v8.sh failed on retired paths"
  while IFS=$'\t' read -r name github uuid expect; do
    [[ "$uuid" = "$expect" ]] || fail "retired uuid for $name at $github is ${uuid:-<missing>}, profile C derivation gives $expect"
  done < <(paste <(jq -r '.[] | .name as $n | .retired[] | [$n, .github, (.uuid // "")] | @tsv' "$DATA/archive.json") "$scratch/retired-v8.txt")
  reused=$(jq -r --slurpfile arch "$DATA/archive.json" '
    ($arch[0] | [.[] | .name as $n | .retired[] | {owner: $n, github, ids: [.uuid]}]) as $ret
    | [.[] | . as $r | $ret[] | select(.ids | index($r.uuid))
       | "\($r.name) has the id retired from \(.owner) at \(.github)"] | join("; ")' "$DATA/repos.json")
  [[ -z "$reused" ]] || fail "a retired id is never minted again: $reused"
fi
echo "check-registry: archive holds $(jq length "$DATA/archive.json") moved repo(s) and $retired retired id(s); all re-derive, none reused, none served"

# 7. Nothing registered is lost (ADR 0008) ----------------------------------
# The uniqueness and retired-id checks above see only what the seed lists, so
# a repo removed from the seed would free its ids for a newcomer on its birth
# path. A registered repo is therefore never removed, and its ids never
# change. CI passes the base branch's repos.json; a local run may omit it.
if [[ -n "${GV_BASE_REPOS_JSON:-}" ]]; then
  [[ -f "$GV_BASE_REPOS_JSON" ]] || fail "GV_BASE_REPOS_JSON names a missing file: $GV_BASE_REPOS_JSON"
  jq empty "$GV_BASE_REPOS_JSON" 2>/dev/null || fail "GV_BASE_REPOS_JSON is not valid JSON"
  # A repo is followed by its id, not its name: a rename keeps the id (U1)
  # and changes `name` and `github` only. A base entry whose uuid the head no
  # longer lists was removed, unless the head lists its name under another id,
  # which is an id change.
  # A base exported before the /v1 reset served the v5 id as `uuid` and the v8
  # id as `uuid_v8`; its v8 id is the one carried forward.
  removed=$(jq -r --slurpfile head "$DATA/repos.json" '
    ($head[0] | map(.uuid)) as $ids | ($head[0] | map(.name)) as $names
    | [.[] | (.uuid_v8 // .uuid) as $bid | select(($bid as $u | $ids | index($u) | not)
                    and (.name as $n | $names | index($n) | not)) | .name] | join(" ")' "$GV_BASE_REPOS_JSON")
  [[ -z "$removed" ]] || fail "registered repo(s) removed from the seed: $removed (ADR 0008: a registered repo is never removed; record its status instead)"
  changed=$(jq -r --slurpfile head "$DATA/repos.json" '
    ($head[0] | map({key: .uuid, value: .}) | from_entries) as $byid
    | ($head[0] | map({key: .name, value: .}) | from_entries) as $byname
    | [.[] | . as $b | ($b.uuid_v8 // $b.uuid) as $bid | ($byid[$bid] // $byname[$b.name]) as $c
       | select($c != null)
       | select($bid != null and $bid != $c.uuid)
       | "\($b.name) (\($bid) -> \($c.uuid))"] | join("; ")' "$GV_BASE_REPOS_JSON")
  [[ -z "$changed" ]] || fail "a registered id changed: $changed (ADR 0008: an id is minted once)"
  echo "check-registry: all $(jq length "$GV_BASE_REPOS_JSON") repos of the base are still registered (followed by id), ids unchanged"
else
  echo "check-registry: NOTICE: GV_BASE_REPOS_JSON unset, so the never-removed check (section 7) did not run"
fi

echo "check-registry: PASS"

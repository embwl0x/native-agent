#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER=$(cd "$SCRIPT_DIR/.." && pwd)/merge_candidate.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-merge-candidate.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

new_repo() {
  local name=$1
  local repo="$TEST_ROOT/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Merge Candidate Test"
  git -C "$repo" config user.email "merge-candidate@example.invalid"
  printf 'base\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  git -C "$repo" commit -q -m "base"
  printf '%s\n' "$repo"
}

make_diverged_candidate() {
  local repo=$1
  git -C "$repo" switch -q -c candidate/finished
  printf 'candidate\n' > "$repo/candidate.txt"
  git -C "$repo" add candidate.txt
  git -C "$repo" commit -q -m "candidate change"
  CANDIDATE_SHA=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q -
  printf 'target\n' > "$repo/target.txt"
  git -C "$repo" add target.txt
  git -C "$repo" commit -q -m "target change"
}

repo=$(new_repo branch-success)
make_diverged_candidate "$repo"
output=$(cd "$repo" && "$HELPER" candidate/finished)
[[ -f "$repo/candidate.txt" ]] || fail "local branch candidate was not applied"
[[ $(git -C "$repo" show -s --format=%s HEAD) == "candidate change" ]] \
  || fail "candidate commit message was not preserved"
git -C "$repo" show -s --format=%B HEAD | grep -q "cherry picked from commit $CANDIDATE_SHA" \
  || fail "candidate source SHA was not recorded"
[[ -z $(git -C "$repo" status --porcelain) ]] || fail "successful branch integration left dirt"
[[ $output == Integrated* ]] || fail "success receipt was not printed"

repo=$(new_repo sha-success)
make_diverged_candidate "$repo"
(cd "$repo" && "$HELPER" "$CANDIDATE_SHA" >/dev/null) \
  || fail "hexadecimal candidate SHA was rejected"
[[ -f "$repo/candidate.txt" ]] || fail "SHA candidate was not applied"

repo=$(new_repo dirty-target)
make_diverged_candidate "$repo"
before=$(git -C "$repo" rev-parse HEAD)
printf 'dirty\n' > "$repo/untracked.txt"
if (cd "$repo" && "$HELPER" candidate/finished >/dev/null 2>&1); then
  fail "dirty target was accepted"
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$before" ]] || fail "dirty-target rejection moved HEAD"
[[ ! -f "$repo/candidate.txt" ]] || fail "dirty-target rejection applied candidate content"

repo=$(new_repo detached-target)
make_diverged_candidate "$repo"
target_branch=$(git -C "$repo" symbolic-ref HEAD)
before=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach
set +e
detached_output=$(cd "$repo" && "$HELPER" candidate/finished 2>&1)
detached_status=$?
set -e
[[ $detached_status -ne 0 ]] || fail "detached target HEAD was accepted"
[[ $detached_output == *"target HEAD is detached"* ]] \
  || fail "detached-target rejection was not explicit"
[[ $(git -C "$repo" rev-parse HEAD) == "$before" ]] || fail "detached-target rejection moved HEAD"
[[ $(git -C "$repo" rev-parse "$target_branch") == "$before" ]] \
  || fail "detached-target rejection moved the intended branch"
[[ ! -f "$repo/candidate.txt" ]] || fail "detached-target rejection applied candidate content"
[[ -z $(git -C "$repo" status --porcelain) ]] || fail "detached-target rejection left dirt"

repo=$(new_repo missing-parent)
git -C "$repo" switch -q -c candidate/stack
printf 'dependency\n' > "$repo/dependency.txt"
git -C "$repo" add dependency.txt
git -C "$repo" commit -q -m "candidate dependency"
printf 'tip\n' > "$repo/tip.txt"
git -C "$repo" add tip.txt
git -C "$repo" commit -q -m "candidate tip"
tip=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q -
before=$(git -C "$repo" rev-parse HEAD)
if (cd "$repo" && "$HELPER" "$tip" >/dev/null 2>&1); then
  fail "candidate with a missing parent was accepted"
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$before" ]] || fail "missing-parent rejection moved HEAD"

repo=$(new_repo conflict-rollback)
git -C "$repo" switch -q -c candidate/conflict
printf 'candidate\n' > "$repo/shared.txt"
git -C "$repo" commit -qam "candidate conflict"
git -C "$repo" switch -q -
printf 'target\n' > "$repo/shared.txt"
git -C "$repo" commit -qam "target conflict"
before=$(git -C "$repo" rev-parse HEAD)
if (cd "$repo" && "$HELPER" candidate/conflict >/dev/null 2>&1); then
  fail "conflicting candidate was accepted"
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$before" ]] || fail "conflict rollback moved HEAD"
[[ $(cat "$repo/shared.txt") == "target" ]] || fail "conflict rollback changed target content"
[[ -z $(git -C "$repo" status --porcelain) ]] || fail "conflict rollback left dirt"

repo=$(new_repo malformed-ref)
before=$(git -C "$repo" rev-parse HEAD)
if (cd "$repo" && "$HELPER" 'HEAD~1' >/dev/null 2>&1); then
  fail "arbitrary revision expression was accepted"
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$before" ]] || fail "malformed-ref rejection moved HEAD"

printf 'ok - merge_candidate accepts finished branches/SHAs and fails cleanly\n'

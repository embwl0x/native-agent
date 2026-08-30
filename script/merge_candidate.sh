#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/merge_candidate.sh <local-branch|commit-sha>

Integrate one finished, single-commit candidate into the current branch.
The target must be clean and already contain the candidate's parent commit.
EOF
}

fail() {
  printf 'merge_candidate: %s\n' "$*" >&2
  exit 2
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

[[ $# -eq 1 ]] || {
  usage >&2
  exit 2
}

candidate_input=$1
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) \
  || fail "run this command inside a Git worktree"
git -C "$repo_root" symbolic-ref --quiet HEAD >/dev/null \
  || fail "target HEAD is detached; check out the intended branch"

[[ -z $(git -C "$repo_root" status --porcelain=v1 --untracked-files=all) ]] \
  || fail "target worktree is not clean"

for marker in CHERRY_PICK_HEAD MERGE_HEAD REBASE_HEAD REVERT_HEAD; do
  marker_path=$(git -C "$repo_root" rev-parse --git-path "$marker")
  [[ ! -e $marker_path ]] || fail "another Git operation is in progress ($marker)"
done
sequencer_path=$(git -C "$repo_root" rev-parse --git-path sequencer)
[[ ! -e $sequencer_path ]] || fail "another Git operation is in progress (sequencer)"

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$candidate_input"; then
  candidate_ref="refs/heads/$candidate_input"
elif [[ $candidate_input =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  candidate_ref=$candidate_input
else
  fail "candidate must be a local branch name or hexadecimal commit SHA"
fi

candidate_commit=$(git -C "$repo_root" rev-parse --verify --quiet "${candidate_ref}^{commit}") \
  || fail "candidate does not resolve to a local commit: $candidate_input"
current_commit=$(git -C "$repo_root" rev-parse --verify HEAD)

if git -C "$repo_root" merge-base --is-ancestor "$candidate_commit" "$current_commit"; then
  fail "candidate is already integrated: $candidate_commit"
fi

read -r -a candidate_line <<<"$(git -C "$repo_root" rev-list --parents -n 1 "$candidate_commit")"
[[ ${#candidate_line[@]} -eq 2 ]] \
  || fail "candidate must be one ordinary commit (root and merge commits are not supported)"
candidate_parent=${candidate_line[1]}

git -C "$repo_root" merge-base --is-ancestor "$candidate_parent" "$current_commit" \
  || fail "candidate parent is not integrated; pass the finished single candidate commit"

git -C "$repo_root" diff --check "$candidate_parent" "$candidate_commit" \
  || fail "candidate contains whitespace errors"

set +e
cherry_pick_output=$(git -C "$repo_root" cherry-pick -x "$candidate_commit" 2>&1)
cherry_pick_status=$?
set -e

if [[ $cherry_pick_status -ne 0 ]]; then
  abort_output=""
  if git -C "$repo_root" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null; then
    set +e
    abort_output=$(git -C "$repo_root" cherry-pick --abort 2>&1)
    abort_status=$?
    set -e
    if [[ $abort_status -ne 0 ]]; then
      printf '%s\n' "$cherry_pick_output" >&2
      printf '%s\n' "$abort_output" >&2
      fail "integration failed and Git could not restore the target; inspect the worktree"
    fi
  fi
  printf '%s\n' "$cherry_pick_output" >&2
  restored_commit=$(git -C "$repo_root" rev-parse --verify HEAD)
  if [[ $restored_commit != "$current_commit" ]] \
    || [[ -n $(git -C "$repo_root" status --porcelain=v1 --untracked-files=all) ]]; then
    fail "integration failed and the target was not restored; inspect the worktree"
  fi
  fail "candidate did not apply cleanly; target restored"
fi

new_commit=$(git -C "$repo_root" rev-parse HEAD)

subject=$(git -C "$repo_root" show -s --format=%s "$new_commit")
printf 'Integrated %s as %s: %s\n' \
  "${candidate_commit:0:12}" "${new_commit:0:12}" "$subject"

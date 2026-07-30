#!/usr/bin/env bash
# script/cleanup_disk_hygiene.sh — routine disk hygiene for NativeAgent
#
# Sweeps the build/runtime cruft that accretes during normal dev:
#   - Stale self-improvement worktrees in data/self_worktrees/
#   - Rotated legacy runtime logs older than the retention window
#   - Old run dirs in data/runs/
#   - __pycache__/, *.pyc, .DS_Store, .pytest_cache/ across the tree
#
# Dry-run by default. Pass --delete to actually remove. Pass --aggressive to
# shorten the age cutoffs. Pass --yes to skip the confirmation prompt
# (still requires --delete).
#
# Usage:
#   ./script/cleanup_disk_hygiene.sh                       # dry-run
#   ./script/cleanup_disk_hygiene.sh --delete              # prompt + delete
#   ./script/cleanup_disk_hygiene.sh --delete --aggressive # tighter cutoffs
#   ./script/cleanup_disk_hygiene.sh --delete --yes        # CI / scripted

set -euo pipefail

# Resolve repo root from this script's location, so it's safe to invoke from
# anywhere.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=true
ASSUME_YES=false
AGGRESSIVE=false

for arg in "$@"; do
    case "$arg" in
        --delete) DRY_RUN=false ;;
        --yes|-y) ASSUME_YES=true ;;
        --aggressive) AGGRESSIVE=true ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

# Age cutoffs (days). Aggressive shortens them.
if $AGGRESSIVE; then
    WORKTREE_AGE=1
    RUN_AGE=7
    LOG_AGE=7
else
    WORKTREE_AGE=3
    RUN_AGE=14
    LOG_AGE=30
fi

MODE_LABEL="DRY-RUN (no changes)"
$DRY_RUN || MODE_LABEL="DELETE (destructive)"
$AGGRESSIVE && MODE_LABEL="$MODE_LABEL [aggressive cutoffs]"

echo "=== NativeAgent Disk Hygiene Cleanup ==="
echo ""
echo "Repo root  : $REPO_ROOT"
echo "Mode       : $MODE_LABEL"
echo "Cutoffs    : worktrees >${WORKTREE_AGE}d, runs >${RUN_AGE}d, logs >${LOG_AGE}d"
echo ""

BEFORE_TOTAL=$(du -sh "$REPO_ROOT" 2>/dev/null | awk '{print $1}')
echo "Total repo size before: $BEFORE_TOTAL"
echo ""

# --- Helpers ---------------------------------------------------------------

# do_delete <description> <find-expr...>
# Lists matches; deletes them if not dry-run.
do_delete() {
    local desc="$1"; shift
    local count=0
    local bytes=0
    # Collect into an array safely (null-delimited).
    local matches=()
    while IFS= read -r -d '' m; do
        matches+=("$m")
    done < <("$@" -print0 2>/dev/null || true)

    count=${#matches[@]}
    if [ "$count" -eq 0 ]; then
        printf "  [%-30s] 0 matches\n" "$desc"
        return 0
    fi

    # Sum bytes (best-effort).
    for m in "${matches[@]}"; do
        if [ -e "$m" ]; then
            local sz
            sz=$(du -sk "$m" 2>/dev/null | awk '{print $1}')
            bytes=$((bytes + ${sz:-0}))
        fi
    done
    local human_mb=$(( bytes / 1024 ))

    printf "  [%-30s] %d matches, ~%d MB\n" "$desc" "$count" "$human_mb"

    if ! $DRY_RUN; then
        for m in "${matches[@]}"; do
            rm -rf "$m"
        done
    fi
}

# --- Pre-flight: confirmation ----------------------------------------------

if ! $DRY_RUN && ! $ASSUME_YES; then
    echo "WARNING: --delete will permanently remove the items listed below"
    echo "         under $REPO_ROOT. Dry-run first if unsure."
    echo ""
    read -r -p "Type YES to proceed: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted — no files deleted."
        exit 1
    fi
    echo ""
fi

# --- Sweep targets ---------------------------------------------------------

echo "1. Stale self-improvement worktrees (data/self_worktrees/*, >${WORKTREE_AGE}d)"
if [ -d data/self_worktrees ]; then
    do_delete "stale worktrees" \
        find data/self_worktrees -maxdepth 1 -mindepth 1 -type d -mtime +"$WORKTREE_AGE"
else
    echo "  (data/self_worktrees not present)"
fi
echo ""

echo "2. Old run directories (data/runs/*, >${RUN_AGE}d)"
if [ -d data/runs ]; then
    do_delete "old runs" \
        find data/runs -maxdepth 1 -mindepth 1 -mtime +"$RUN_AGE"
else
    echo "  (data/runs not present)"
fi
echo ""

echo "3. Rotated logs (data/logs/*.log.* and data/logs/*.gz, >${LOG_AGE}d)"
if [ -d data/logs ]; then
    do_delete "old rotated logs" \
        find data/logs -type f \( -name "*.log.*" -o -name "*.gz" \) -mtime +"$LOG_AGE"
else
    echo "  (data/logs not present)"
fi
echo ""

echo "4. Python bytecode caches (__pycache__/, *.pyc)"
do_delete "__pycache__ dirs" \
    find . -path ./.venv -prune -o -path ./node_modules -prune -o -type d -name __pycache__ -print
do_delete "*.pyc files" \
    find . -path ./.venv -prune -o -path ./node_modules -prune -o -type f -name "*.pyc" -print
echo ""

echo "5. macOS metadata (.DS_Store)"
do_delete ".DS_Store files" \
    find . -path ./.venv -prune -o -type f -name ".DS_Store" -print
echo ""

echo "6. Pytest cache (.pytest_cache/)"
do_delete ".pytest_cache dirs" \
    find . -path ./.venv -prune -o -type d -name ".pytest_cache" -print
echo ""

# --- After ----------------------------------------------------------------

AFTER_TOTAL=$(du -sh "$REPO_ROOT" 2>/dev/null | awk '{print $1}')
echo "Total repo size after : $AFTER_TOTAL"
echo ""

if $DRY_RUN; then
    echo "DRY-RUN complete — nothing was deleted."
    echo "Re-run with --delete to actually remove the items above."
    echo "Add --aggressive to shorten the age cutoffs."
else
    echo "Cleanup complete."
fi

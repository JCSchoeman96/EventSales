#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"

if [[ "$MODE" != "--check" && "$MODE" != "--sync" ]]; then
  echo "Usage: scripts/sync_with_origin_main.sh [--check|--sync]"
  exit 2
fi

problem() {
  local message="$1"
  local why="$2"
  local fix="$3"

  echo
  echo "Problem: ${message}"
  echo "Why: ${why}"
  echo "Fix: ${fix}"
}

git_dir_path() {
  git rev-parse --git-dir
}

has_unresolved_conflicts() {
  [[ -n "$(git diff --name-only --diff-filter=U)" ]]
}

has_in_progress_operation() {
  local git_dir
  git_dir="$(git_dir_path)"

  [[ -f "${git_dir}/MERGE_HEAD" ]] ||
    [[ -d "${git_dir}/rebase-merge" ]] ||
    [[ -d "${git_dir}/rebase-apply" ]] ||
    [[ -f "${git_dir}/CHERRY_PICK_HEAD" ]] ||
    [[ -f "${git_dir}/REVERT_HEAD" ]] ||
    [[ -f "${git_dir}/BISECT_LOG" ]]
}

origin_main_state() {
  local ahead="$1"
  local behind="$2"

  if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
    echo "current"
  elif [[ "$ahead" == "0" ]]; then
    echo "behind"
  elif [[ "$behind" == "0" ]]; then
    echo "ahead"
  else
    echo "diverged"
  fi
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Problem: not inside a Git repository"
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"

if [[ -z "$CURRENT_BRANCH" ]]; then
  echo "Problem: detached HEAD"
  echo "Fix: check out a branch before syncing"
  exit 1
fi

echo "Git sync"
echo "|> branch: ${CURRENT_BRANCH}"
echo "|> mode: ${MODE}"

git fetch origin --prune

if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  problem \
    "origin/main not found" \
    "the sync script can only compare against a fetched origin/main ref" \
    "confirm the remote name and default branch before syncing"
  exit 1
fi

STATUS_SHORT="$(git status --short)"
DIRTY_TREE="no"

if [[ -n "$STATUS_SHORT" ]]; then
  DIRTY_TREE="yes"
fi

IN_PROGRESS="no"
if has_in_progress_operation; then
  IN_PROGRESS="yes"
fi

HAS_CONFLICTS="no"
if has_unresolved_conflicts; then
  HAS_CONFLICTS="yes"
fi

read -r AHEAD BEHIND < <(git rev-list --left-right --count HEAD...origin/main)
ORIGIN_MAIN_STATE="$(origin_main_state "$AHEAD" "$BEHIND")"

echo "|> clean: $([[ "$DIRTY_TREE" == "no" ]] && echo "yes" || echo "no")"
echo "|> conflicts: ${HAS_CONFLICTS}"
echo "|> in-progress: ${IN_PROGRESS}"
echo "|> compared-to-origin-main: ahead=${AHEAD} behind=${BEHIND}"
echo "|> origin/main: ${ORIGIN_MAIN_STATE}"

if [[ "$MODE" == "--check" ]]; then
  CHECK_SAFE="yes"
  CHECK_ACTION="none"

  if [[ "$DIRTY_TREE" == "yes" ]]; then
    CHECK_SAFE="no"
    CHECK_ACTION="stopped"
    problem \
      "working tree has local changes" \
      "syncing should only happen after you intentionally commit, stash, or discard local work" \
      "review git status and clean the branch before running --sync"
  fi

  if [[ "$HAS_CONFLICTS" == "yes" ]]; then
    CHECK_SAFE="no"
    CHECK_ACTION="stopped"
    problem \
      "branch has unresolved conflicts" \
      "rebases and merges must not continue while conflicts are unresolved" \
      "resolve or abort the current Git operation before running --sync"
  fi

  if [[ "$IN_PROGRESS" == "yes" ]]; then
    CHECK_SAFE="no"
    CHECK_ACTION="stopped"
    problem \
      "another Git operation is already in progress" \
      "merge, rebase, cherry-pick, revert, or bisect state must be completed first" \
      "finish or abort the in-progress operation before running --sync"
  fi

  if [[ "$CURRENT_BRANCH" == "main" && "$ORIGIN_MAIN_STATE" == "ahead" ]]; then
    CHECK_SAFE="no"
    CHECK_ACTION="stopped"
    problem \
      "main is ahead of origin/main" \
      "starting fresh work on a local-only main branch risks stacking work on top of unreviewed history" \
      "inspect main manually before starting work"
  fi

  if [[ "$ORIGIN_MAIN_STATE" == "diverged" ]]; then
    CHECK_SAFE="no"
    CHECK_ACTION="stopped"
    problem \
      "branch has diverged from origin/main" \
      "starting work before reconciling both histories risks conflicts and accidental history rewrites later" \
      "inspect the branch manually and reconcile it before starting work"
  fi

  if [[ "$CHECK_SAFE" == "yes" && "$ORIGIN_MAIN_STATE" == "behind" ]]; then
    CHECK_ACTION="sync-available"
  fi

  echo "|> action: ${CHECK_ACTION}"

  if [[ "$CHECK_SAFE" == "yes" ]]; then
    exit 0
  fi

  exit 1
fi

if [[ "$DIRTY_TREE" == "yes" ]]; then
  echo "|> action: stopped"
  problem \
    "working tree has local changes" \
    "syncing could overwrite or conflict with local work" \
    "commit, stash, or discard intentionally before syncing"
  git status --short --branch
  exit 1
fi

if [[ "$HAS_CONFLICTS" == "yes" ]]; then
  echo "|> action: stopped"
  problem \
    "branch has unresolved conflicts" \
    "the sync script never auto-resolves merge or rebase conflicts" \
    "resolve conflicts manually or abort the current operation before syncing"
  exit 1
fi

if [[ "$IN_PROGRESS" == "yes" ]]; then
  echo "|> action: stopped"
  problem \
    "another Git operation is already in progress" \
    "merge, rebase, cherry-pick, revert, or bisect state must be completed first" \
    "finish or abort the in-progress operation before syncing"
  exit 1
fi

if [[ "$CURRENT_BRANCH" == "main" ]]; then
  if [[ "$ORIGIN_MAIN_STATE" == "current" ]]; then
    echo "|> action: none"
    exit 0
  fi

  if [[ "$ORIGIN_MAIN_STATE" == "behind" ]]; then
    echo "|> action: git merge --ff-only origin/main"

    if ! git merge --ff-only origin/main; then
      problem \
        "fast-forward merge failed" \
        "main can only be updated safely when Git can fast-forward without rewriting history" \
        "inspect main manually before trying to sync again"
      exit 1
    fi

    exit 0
  fi

  echo "|> action: stopped"
  problem \
    "main is ahead of or diverged from origin/main" \
    "the sync script never rewrites or auto-reconciles main history" \
    "inspect main manually before syncing"
  exit 1
fi

if [[ "$ORIGIN_MAIN_STATE" == "current" ]]; then
  echo "|> action: none"
  exit 0
fi

if [[ "$ORIGIN_MAIN_STATE" == "ahead" ]]; then
  echo "|> action: stopped"
  problem \
    "feature branch has local commits and origin/main has no newer commits" \
    "there is nothing to sync from origin/main right now" \
    "continue working or inspect the branch manually if you expected new upstream changes"
  exit 0
fi

if git rev-parse --verify "refs/remotes/origin/${CURRENT_BRANCH}" >/dev/null 2>&1; then
  echo "|> action: stopped"
  problem \
    "branch exists on origin" \
    "rebasing a pushed or shared branch rewrites published history" \
    "ask for approval before rebasing a branch that already exists on origin"
  exit 1
fi

echo "|> action: rebase onto origin/main"

if ! git rebase origin/main; then
  problem \
    "rebase stopped with conflicts or another error" \
    "the sync script never auto-resolves rebase problems" \
    "resolve manually, or abort with git rebase --abort, before continuing"
  exit 1
fi

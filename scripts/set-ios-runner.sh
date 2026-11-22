#!/usr/bin/env bash
# set-ios-runner.sh <repo-dir-under-~/Dev/GitHub> [--push] [--runner xcode-27]
# Points release-ios.yml at the given GitHub runner (default xcode-27 = Xcode 27 / iOS 27 SDK,
# ITMS-90725). Works in a throwaway worktree off origin's default branch, so local
# checkouts are untouched. Without --push it only prints the diff.
set -euo pipefail
REPO=$1; shift
PUSH=""; RUNNER=xcode-27
while [ $# -gt 0 ]; do
  case $1 in --push) PUSH=1 ;; --runner) RUNNER=$2; shift ;; esac; shift
done
R=~/Dev/GitHub/$REPO
cd "$R"
git fetch -q origin
DEF=$(git symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's#origin/##' || true); DEF=${DEF:-main}
F=.github/workflows/release-ios.yml
git cat-file -e "origin/$DEF:$F" 2>/dev/null || { echo "== $REPO: no $F, skip"; exit 0; }
WT=$(mktemp -d)/wt
git worktree add -q --detach "$WT" "origin/$DEF"
trap 'git -C "$R" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
cd "$WT"
perl -pi -e "s/^(\s*runs-on:\s*)macos-[0-9a-z-]+\s*\$/\${1}$RUNNER\n/" "$F"
if git diff --quiet -- "$F"; then echo "== $REPO: already $RUNNER (or no macos runner)"; exit 0; fi
echo "== $REPO ($DEF)"; git diff --stat -- "$F"
if [ -n "$PUSH" ]; then
  git commit -q "$F" -m "ci(ios): build on the $RUNNER runner (iOS 27 SDK, ITMS-90725)"
  git push -q origin "HEAD:$DEF" && echo "  pushed $(git rev-parse --short HEAD) -> $DEF"
fi

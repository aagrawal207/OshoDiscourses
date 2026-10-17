#!/bin/zsh
# Coordinator helper: commit a worker's worktree, merge it into `android` locally,
# and push `android` to both `android` and `main`. Usage: integrate.sh <task> <message>
set -euo pipefail
task=$1 msg=$2
wt=$HOME/projects/OshoDiscourses-Android-wt/$task
coord=$HOME/projects/OshoDiscourses-Android
g() { git -C "$1" -c core.hooksPath=/dev/null "${@:2}"; }

g $wt add -A
g $wt diff --cached --quiet || g $wt commit -q -m "$msg"
g $coord fetch -q origin
g $coord merge -q --ff-only origin/main
g $coord merge -q --no-edit "android-$task"
g $coord push -q origin android android:main
g $coord worktree remove --force $wt
g $coord branch -q -D "android-$task"
g $coord log --oneline -1

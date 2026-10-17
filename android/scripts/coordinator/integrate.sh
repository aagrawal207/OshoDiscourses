#!/bin/zsh
# Coordinator helper: commit a worker's worktree, open a PR into `android`, merge it,
# and fast-forward the coordinator worktree. Usage: integrate.sh <task> <issue> <title> [body-file]
set -euo pipefail
task=$1 issue=$2 title=$3 body_file=${4:-}
wt=$HOME/projects/OshoDiscourses-Android-wt/$task
coord=$HOME/projects/OshoDiscourses-Android
g() { git -C "$1" -c core.hooksPath=/dev/null "${@:2}"; }

g $wt add -A android .github 2>/dev/null || g $wt add -A android
if ! g $wt diff --cached --quiet; then
  g $wt commit -q -m "$title" -m "Part of #$issue."
fi
g $wt fetch -q origin android
g $wt merge -q --no-edit origin/android
g $wt push -q -u origin android-$task
body="Closes #$issue (on the \`android\` branch)."
[[ -n $body_file ]] && body="$body

$(cat $body_file)"
pr=$(gh pr create -R aagrawal207/OshoDiscourses -B android -H android-$task -t "$title" -b "$body" -l android 2>/dev/null || gh pr view -R aagrawal207/OshoDiscourses android-$task --json url -q .url)
echo "PR: $pr"
gh pr merge -R aagrawal207/OshoDiscourses android-$task --merge --delete-branch=false >/dev/null
gh issue close -R aagrawal207/OshoDiscourses $issue -c "Merged in $pr." >/dev/null 2>&1 || true
g $coord pull -q --ff-only origin android
g $coord log --oneline -1

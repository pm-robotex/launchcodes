#!/usr/bin/env bash
# cleanup.sh <WT>
# Step 7, always: after a launch, a stop, a failure or a dry run. Removes the clean copy. It never deletes anything
# by hand: only `git worktree remove`, and only for a folder whose name starts with launch-.
set -u
WT="${1:?usage: cleanup.sh <WT>}"
case "$(basename "$WT")" in launch-*) ;; *) echo "REFUSED: $WT isn't a launchcodes clean copy (those folders start with launch-)"; exit 1 ;; esac
[ -f "$WT/.launch-state" ] || { echo "nothing to clean in $WT (already cleaned?)"; exit 0; }
. "$WT/.launch-state"
if [ -L "$WT/node_modules" ]; then
  echo "STOP: $WT/node_modules is a link to another folder, and removing the copy could follow it."
  echo "Remove the link itself first (rm \"$WT/node_modules\", without -r), then run cleanup again."; exit 1
fi
out="$(git -c core.longpaths=true -C "$R" worktree remove --force "$WT" 2>&1)"; git -C "$R" worktree prune
if [ -e "$WT" ]; then
  echo "FOLDER SURVIVED: $WT. Usually a program still has it open (a dev server, an editor): close it and run cleanup again."
  [ -n "$out" ] && echo "git said: $out"
  exit 1
fi
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" CLEANED "-" >> "$LOG" 2>/dev/null
echo "CLEANED  $WT"

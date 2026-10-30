# Changelog

Safety fixes are marked **safety**. Update with `git -C ~/.claude/skills/launchcodes pull`.

## 0.2.2 (October 2026)

From five more real releases:
- A slow host build no longer looks like a failure. When the live check runs out of time but your host still says
  it's deploying (one Vercel build took 11 minutes instead of 2), it says STILL BUILDING, and Claude runs the
  check once more before reporting.
- The release list marks a release that already has an open launchcodes copy (another chat may be launching it),
  and preparing the same commit again says so too.

## 0.2.1 (October 2026)

- First-run setup: in a project without `.claude/launchcodes.json`, the first `/launchcodes` offers to create it
  from your answers (your live domain and, for Supabase, your production project id). Claude never guesses them;
  the file is checked before and after it is written and never overwrites an existing one. Without it, every
  release asked which Supabase project is production, and a release could only end as "Published", not "Live".

## 0.2.0 (October 2026)

From the first ten real releases with launchcodes.

- `/launchcodes` on its own lists the releases that are ready, numbered, and you pick one. Claude no longer
  guesses which commit you meant from the conversation.
- **safety** Changed Supabase edge functions are listed: a push never deploys them.
- **safety** Edited migration files are listed with the new ones (an edit to a file that already ran may need
  applying again).
- **safety** Commits already on the production branch that your host never put live (a failed or blocked build)
  are listed: they go live with this release.
- **safety** The database check reads the columns of rows built in a variable or a helper function in the same
  file, and checks each written column on its own line. One release had added a column this way unseen.
- Live check: "Live" when your page or its main script carries this release's commit id. A refused deployment
  shows your host's own reason and link, and says when it's a setting rather than your code.
- New setting `releaseCommit`: each release lands as one merge commit titled `Ship <code> · <name>`, so your host's
  deployment list and GitHub show the release's name.
- The push prompt shows the release's name next to its launch code.
- The "clean copies left over" list shows only launchcodes' own; the not-on-top-of-production message no longer
  suggests rewriting a shared branch.

## 0.1.0 (October 2026)

First public release.

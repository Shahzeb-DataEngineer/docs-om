#!/usr/bin/env bash
# Posts one Slack message when a Major Release Watcher run finishes: pass or
# fail, the failed job and step names, a link to the run, and the issues the
# notify step created (or would create, in a dry run) with their links.
# Runs in the final `report` job (`if: always()`), so it also fires when an
# earlier job failed. Off-week runs (the cron fires every Monday, work happens
# on even weeks) finish as a no-op success and send nothing.
#
# Usage: watcher-slack-report.sh <report-file>
#   report-file  text written by watcher-notify.sh (SLACK_FILE); may be missing
# Env:   WATCHER_NAME, VERSION, RUN_THIS_WEEK ("true" on a working run),
#        SETUP_RESULT, SCAN_RESULT, NOTIFY_RESULT (job results from `needs`),
#        DRY_RUN ("true" for a preview run), RUN_URL, RUN_ID, GITHUB_REPOSITORY,
#        GH_TOKEN (to name the failed steps), SLACK_WEBHOOK_URL,
#        PRINT_ONLY=1 (print the message instead of posting, for local tests).
set -euo pipefail

REPORT="${1:-}"
NAME="${WATCHER_NAME:-Major Release Watcher}"
REPO="${GITHUB_REPOSITORY:-}"

failed=false
for r in "${SETUP_RESULT:-}" "${SCAN_RESULT:-}" "${NOTIFY_RESULT:-}"; do
  case "$r" in failure|cancelled) failed=true ;; esac
done

if [ "$failed" = "false" ] && [ "${RUN_THIS_WEEK:-}" != "true" ]; then
  echo "Off-week run, nothing to report."; exit 0
fi

mode=""; [ "${DRY_RUN:-}" = "true" ] && mode=" (dry run)"
ver=""; [ -n "${VERSION:-}" ] && ver=" for ${VERSION}"

if [ "$failed" = "true" ]; then
  head=":x: *${NAME}* (${REPO#*/}) failed${ver}${mode}"
  steps=""
  if [ -n "${RUN_ID:-}" ] && [ -n "$REPO" ]; then
    steps=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --paginate \
      --jq '.jobs[] | select(.conclusion == "failure") | "\(.name): " + ([.steps[]? | select(.conclusion == "failure") | .name] | join(", "))' 2>/dev/null || true)
  fi
  [ -n "$steps" ] && detail=$'\nFailed step(s):\n'"$(sed 's/^/• /' <<< "$steps")" || detail=$'\nSetup, scan and notify results: '"${SETUP_RESULT:-?}, ${SCAN_RESULT:-?}, ${NOTIFY_RESULT:-?}"
else
  head=":white_check_mark: *${NAME}* (${REPO#*/}) passed${ver}${mode}"
  detail=""
fi

body=""
if [ -n "$REPORT" ] && [ -s "$REPORT" ]; then
  # Slack treats & < > as markup; the issue titles in this file are model-written.
  body=$'\n\n'"$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$REPORT")"
elif [ "$failed" = "false" ]; then
  body=$'\n\nNo issues created.'
fi

link=""; [ -n "${RUN_URL:-}" ] && link=$'\n'"<${RUN_URL}|View run>"
text="${head}${detail}${body}${link}"

if [ "${PRINT_ONLY:-}" = "1" ]; then printf '%s\n' "$text"; exit 0; fi
if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "Slack not configured (missing SLACK_WEBHOOK_URL secret); skipping."; exit 0
fi
curl -sS -X POST "$SLACK_WEBHOOK_URL" -H "Content-type: application/json; charset=utf-8" \
  --data "$(jq -n --arg text "$text" '{text: $text}')"

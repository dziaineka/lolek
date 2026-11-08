#!/usr/bin/env bash
# Runs all live corpus checks (the no-gallery and the gallery profiles) and
# shows one summary of both. Arguments go to the runner of each profile, for
# example: scripts/live-corpus-test.sh --service twitter --limit 4
#
# Exit status: 1 when a case regressed, 2 when a result is inconclusive or a
# profile did not finish, otherwise 0.
set -uo pipefail

report_dir="${LIVE_CORPUS_REPORT_DIR:-live-corpus-reports}"
mkdir -p "$report_dir"

# Each entry is "<profile>:<flake app>".
runs=(no-gallery:live-corpus-check gallery:live-corpus-gallery-check)
codes=()

for run in "${runs[@]}"; do
  profile=${run%%:*}
  report="$report_dir/$profile.json"
  rm -f "$report"
  echo "=== live corpus: $profile profile"
  nix run ".#${run#*:}" -- --report "$report" "$@"
  codes+=("$?")
done

echo
echo "=== live corpus summary"
status=0
for index in "${!runs[@]}"; do
  profile=${runs[$index]%%:*}
  report="$report_dir/$profile.json"
  code=${codes[$index]}
  if [[ ! -s "$report" ]]; then
    echo "$profile: no report (exit status $code)"
    status=$((status == 1 ? 1 : 2))
    continue
  fi

  jq -r --arg profile "$profile" --arg code "$code" '
    "\($profile): \(.results | length) cases; "
      + ([.results[].verdict] | group_by(.) | map("\(.[0])=\(length)") | join(", "))
      + " (exit status \($code))",
    (.results[]
      | select(.verdict != "pass" and .verdict != "known_failure")
      | "  \(.verdict): \(.id)"
        + (if .error then " - " + (.error | gsub("\\s+"; " ") | .[0:160]) else "" end))
  ' "$report"

  case "$code" in
    0) ;;
    1) status=1 ;;
    *) status=$((status == 1 ? 1 : 2)) ;;
  esac
done

echo "reports: $report_dir/"
exit "$status"

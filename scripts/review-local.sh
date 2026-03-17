#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/review-local.sh [staged|unstaged|last-commit]
  ./scripts/review-local.sh range <git-range>

Examples:
  ./scripts/review-local.sh staged
  ./scripts/review-local.sh unstaged
  ./scripts/review-local.sh last-commit
  ./scripts/review-local.sh range HEAD~3..HEAD
EOF
}

mode="${1:-staged}"
range_arg="${2:-}"

case "$mode" in
  staged)
    diff_cmd=(git diff --cached)
    files_cmd=(git diff --cached --name-only --diff-filter=ACMR)
    label="staged changes"
    ;;
  unstaged)
    diff_cmd=(git diff)
    files_cmd=(git diff --name-only)
    label="unstaged changes"
    ;;
  last-commit)
    diff_cmd=(git show --stat --patch --format=medium HEAD)
    files_cmd=(git diff-tree --no-commit-id --name-only -r HEAD)
    label="last commit"
    ;;
  range)
    if [[ -z "$range_arg" ]]; then
      usage
      exit 1
    fi
    diff_cmd=(git diff "$range_arg")
    files_cmd=(git diff --name-only "$range_arg")
    label="range $range_arg"
    ;;
  *)
    usage
    exit 1
    ;;
esac

patch_file="$(mktemp -t office-resume-review.XXXXXX.patch)"
"${diff_cmd[@]}" > "$patch_file"

echo "Review target: $label"
echo
echo "Changed files:"
"${files_cmd[@]}" || true
echo
echo "Patch saved to: $patch_file"
echo
cat <<EOF
Suggested Codex prompt:
review my $label in /Users/ilya.baimetov/Projects/msoffice-resume; focus on bugs, regressions, missing tests, spec drift, and security issues. Findings first.
EOF

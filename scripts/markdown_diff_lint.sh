#!/usr/bin/env bash
# This script runs markdownlint-cli2 on changed files.
# Usage: ./markdown_lint.sh <files to lint>

set -eo pipefail

if ! command markdownlint-cli2 dummy.md &>/dev/null; then
  echo "markdownlint-cli2 needs to be installed."
  echo "Install it by running npm install -g markdownlint-cli2"
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "No provided files to check"
  exit
fi

COLOR_RED='\033[0;31m'
COLOR_BOLD='\033[1m'
COLOR_ORANGE='\033[0;33m'
COLOR_NONE='\033[0m' # No Color

function log_error {
  echo -n -e "${COLOR_BOLD}${COLOR_RED}$*${COLOR_NONE}\n"
}

function log_warning {
  echo -n -e "${COLOR_ORANGE}$*${COLOR_NONE}\n"
}

CHANGED_FILES="$*"
GIT_REMOTE=${GIT_REMOTE:-origin}

if [ -z "${BASE_REF}" ]; then
  echo "Empty base reference (\$BASE_REF), assuming: main"
  BASE_REF=main
fi

if [ -z "${BASE_CLONE_URL}" ]; then
  BASE_CLONE_URL="$(git remote get-url "${GIT_REMOTE}")"
  echo "Empty base clone URL (\$BASE_CLONE_URL), assuming: ${BASE_CLONE_URL}"
fi

if [ -z "${HEAD_CLONE_URL}" ]; then
  HEAD_CLONE_URL="${BASE_CLONE_URL}"
  echo "Empty base clone URL (\$HEAD_CLONE_URL), assuming: ${HEAD_CLONE_URL}"
fi

MD_LINT_URL_PREFIX="https://github.com/DavidAnson/markdownlint/blob/main/doc/"

if [ "${BASE_CLONE_URL}" != "${HEAD_CLONE_URL}" ]; then
  GIT_REMOTE=base
  git remote add "${GIT_REMOTE}" "${BASE_CLONE_URL}"
  git fetch "${GIT_REMOTE}" "${BASE_REF}"
  trap 'git remote remove "${GIT_REMOTE}"' EXIT
fi

declare -A files_with_failures start_ranges end_ranges
for file in ${CHANGED_FILES}; do
  # Find start and end ranges from changed files.
  start_ranges=()
  end_ranges=()
  # From https://github.com/paleite/eslint-plugin-diff/blob/46c5bcf296e9928db19333288457bf2805aad3b9/src/git.ts#L8-L27
  ranges=$(git diff "${GIT_REMOTE}"/"${BASE_REF}" \
           --diff-algorithm=histogram \
           --diff-filter=ACM \
           --find-renames=100% \
           --no-ext-diff \
           --relative \
           --unified=0 -- "${file}" | \
    awk 'match($0, /^@@\s-[0-9,]+\s\+([0-9]+)(,([0-9]+))?/, m) { \
               print m[1] ":" m[1] + ((m[3] == "") ? "0" : m[3]) }')
  i=0
  for range in ${ranges}; do
    start_ranges["${i}"]=$(echo "${range}" | awk -F: '{print $1}')
    end_ranges["${i}"]=$(echo "${range}" | awk -F: '{print $2}')
    i=$((1 + i))
  done
	if [ -z "${ranges}" ]; then
    start_ranges[0]=0
    end_ranges[0]=0
  fi

  i=0
  markdownlint-cli2 "${file}" 2>/dev/null || true
  while IFS= read -r line; do
    line_number=$(echo "${line}" | awk -F: '{print $2}' | awk '{print $1}')
    while [ "${i}" -lt "${#end_ranges[@]}" ] && [ "${line_number}" -gt "${end_ranges["${i}"]}" ]; do
      i=$((1 + i))
    done
    rule=$(echo "${line}" | awk 'match($2, /([^\/]+)/, m) {print tolower(m[1])}')
    lint_error="${line} (${MD_LINT_URL_PREFIX}${rule}.md)"

    if [ "${i}" -lt "${#start_ranges[@]}" ] && [ "${line_number}" -ge "${start_ranges["${i}"]}" ] && [ "${line_number}" -le "${end_ranges["${i}"]}" ]; then
      # Inside range with changes, raise an error.
      if [ -z "${GITHUB_ACTIONS}" ]; then
        log_error "${lint_error}"
      else
        echo "::add-matcher::.github/workflows/markdownlint-problem-matcher.json"
        echo "${lint_error}"
        echo "::remove-matcher owner=markdownlint::"
      fi
      files_with_failures["${file}"]=1
    else
      # Outside of range, raise a warning.
      if [ -z "${GITHUB_ACTIONS}" ]; then
        log_warning "${lint_error}"
      else
        echo "::warning::${lint_error}"
      fi
    fi
  done < <(markdownlint-cli2 "${file}" 2>&1 >/dev/null || true)
done

echo "Finished linting"

for file in "${!files_with_failures[@]}"; do
  if [ -z "${GITHUB_ACTIONS}" ]; then
    log_error "${file} has linting issues"
  else
    echo "::error::${file} has linting issues"
  fi
done
if [ "${#files_with_failures[@]}" -gt "0" ]; then
  exit 1
fi

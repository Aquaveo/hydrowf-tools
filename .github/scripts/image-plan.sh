#!/usr/bin/env bash
# Which tool images a CI run builds, as a GitHub Actions matrix: {"include": [{"tool", "dir", "version", "push"}]}.
#
#   image-plan.sh <event> <ref name> [<pull request base sha>]
#
# A tool is a directory <group>/<tool>/ with a Dockerfile, the groups being TOOL_GROUPS (nextgen/ for NextGen,
# evaluation/ for model-agnostic evaluation tools, fim/ for FIM); its image is ghcr.io/aquaveo/<tool>, so a
# tool's name is unique across groups.
#   push of a tag <tool>/v<version>  that tool, pushed as <version> (the tag is the only version source)
#   pull_request                     the tools whose directory changed (all when CI itself changed), not pushed
#   anything else (workflow_dispatch) every tool, not pushed
set -euo pipefail
TOOL_GROUPS=(nextgen evaluation fim)

tool_dirs() {                   # every tool with a Dockerfile, as <group>/<tool>
    local dockerfile
    for group in "${TOOL_GROUPS[@]}"; do
        for dockerfile in "$group"/*/Dockerfile; do
            if [ -f "$dockerfile" ]; then dirname "$dockerfile"; fi     # a group may have none (fim/)
        done
    done
}

entry() {                       # <group>/<tool> <version> <push>
    printf '{"tool":"%s","dir":"%s","version":"%s","push":%s}' "$(basename "$1")" "$1" "$2" "$3"
}

matrix() {                      # entries on stdin, one per line -> the matrix JSON
    local entries
    entries=$(paste -sd, -)
    printf '{"include":[%s]}\n' "$entries"
}

dirs=$(tool_dirs)
repeated=$(xargs -n1 basename <<<"$dirs" | sort | uniq -d)
if [ -n "$repeated" ]; then
    echo "::error::tool names must be unique across ${TOOL_GROUPS[*]} (one image each): $repeated" >&2
    exit 1
fi

event=$1 ref=$2 base=${3:-}
case $event in
    push)
        tool=${ref%%/v*} version=${ref#*/v}
        dir=""
        for d in $dirs; do [ "$(basename "$d")" = "$tool" ] && dir=$d; done   # literal: no pattern in a tag
        if [[ $ref != */v* || -z $dir ]]; then
            echo "::error::$ref is not a release tag <tool>/v<version> of a tool with a Dockerfile" >&2
            exit 1
        fi
        entry "$dir" "$version" true | matrix
        ;;
    pull_request)
        changed=$(git diff --name-only "$base"...HEAD)
        for dir in $dirs; do
            if grep -q -e "^$dir/" -e '^\.github/' <<<"$changed"; then
                entry "$dir" pr false; echo
            fi
        done | sed '/^$/d' | matrix
        ;;
    *)
        for dir in $dirs; do entry "$dir" manual false; echo; done | sed '/^$/d' | matrix
        ;;
esac

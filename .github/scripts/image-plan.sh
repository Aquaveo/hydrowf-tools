#!/usr/bin/env bash
# Which tool images a CI run builds, as a GitHub Actions matrix: {"include": [{"tool", "version", "push"}]}.
#
#   image-plan.sh <event> <ref name> [<pull request base sha>]
#
# A tool is a directory nextgen/<tool>/ with a Dockerfile; its image is ghcr.io/aquaveo/<tool>.
#   push of a tag <tool>/v<version>  that tool, pushed as <version> (the tag is the only version source)
#   pull_request                     the tools whose directory changed (all when CI itself changed), not pushed
#   anything else (workflow_dispatch) every tool, not pushed
set -euo pipefail

tools() {                       # every tool with a Dockerfile
    for dockerfile in nextgen/*/Dockerfile; do basename "$(dirname "$dockerfile")"; done
}

entry() {                       # <tool> <version> <push>
    printf '{"tool":"%s","version":"%s","push":%s}' "$1" "$2" "$3"
}

matrix() {                      # entries on stdin, one per line -> the matrix JSON
    local entries
    entries=$(paste -sd, -)
    printf '{"include":[%s]}\n' "$entries"
}

event=$1 ref=$2 base=${3:-}
case $event in
    push)
        tool=${ref%%/v*} version=${ref#*/v}
        if [[ $ref != */v* || ! -f nextgen/$tool/Dockerfile ]]; then
            echo "::error::$ref is not a release tag <tool>/v<version> of a tool with a Dockerfile" >&2
            exit 1
        fi
        entry "$tool" "$version" true | matrix
        ;;
    pull_request)
        changed=$(git diff --name-only "$base"...HEAD)
        for tool in $(tools); do
            if grep -q -e "^nextgen/$tool/" -e '^\.github/' <<<"$changed"; then
                entry "$tool" pr false; echo
            fi
        done | sed '/^$/d' | matrix
        ;;
    *)
        for tool in $(tools); do entry "$tool" manual false; echo; done | sed '/^$/d' | matrix
        ;;
esac

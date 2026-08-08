#!/bin/sh

set -eu

project_file="DarkSpeed.xcodeproj/project.pbxproj"
marketing_version=$(awk -F ' = ' '/MARKETING_VERSION =/ {
    value = $2
    sub(/;.*/, "", value)
    print value
    exit
}' "$project_file")
build_version=$(awk -F ' = ' '/CURRENT_PROJECT_VERSION =/ {
    value = $2
    sub(/;.*/, "", value)
    print value
    exit
}' "$project_file")

if [ -z "$marketing_version" ] || [ -z "$build_version" ]; then
    echo "Unable to read the DarkSpeed version from $project_file" >&2
    exit 1
fi

printf '%s-%s\n' "$marketing_version" "$build_version"

#!/bin/bash

# Exit early.
# See: https://www.gnu.org/savannah-checkouts/gnu/bash/manual/bash.html#The-Set-Builtin.
set -e

# Source dot env file.
source .env

# Arguments.
tags=""
snapshot_version=""
dry_run=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tags)
      tags="$2"
      shift 2
      ;;
    --snapshot-version)
      snapshot_version="${2//v/}"
      shift 2
      ;;
    --dry-run)
      dry_run="$2"
      shift 2
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

echo "Clean tag(s) 🧹"
echo

IFS=',' read -ra tags_to_delete <<< "$tags"
if [ -n "$snapshot_version" ]; then
  tags_to_delete+=("$DOCKER_REGISTRY/snapshot:$snapshot_version")
  tags_to_delete+=("$DOCKER_REGISTRY/snapshot:$snapshot_version-cloudrun")
  tags_to_delete+=("$DOCKER_REGISTRY/snapshot:$snapshot_version-aws-lambda")
fi

echo "Will delete the following tag(s):"
for tag in "${tags_to_delete[@]}"; do
  echo "- $tag"
done

if [ "$dry_run" = "true" ]; then
  echo "🚧 Dry run"
fi
echo

# Separate tags by registry.
ghcr_tags=()
dockerhub_tags=()

for tag in "${tags_to_delete[@]}"; do
  if [[ "$tag" == ghcr.io/* ]]; then
    ghcr_tags+=("$tag")
  else
    dockerhub_tags+=("$tag")
  fi
done

# Delete ghcr.io tags via GitHub API.
if [ "${#ghcr_tags[@]}" -gt 0 ]; then
  if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️ GITHUB_TOKEN not set, skipping ghcr.io cleanup"
    echo
  else
    for tag in "${ghcr_tags[@]}"; do
      remainder="${tag#ghcr.io/}"
      owner="${remainder%%/*}"
      pkg_tag="${remainder#*/}"
      package_name="${pkg_tag%%:*}"
      tag_name="${pkg_tag##*:}"

      if [ "$dry_run" = "true" ]; then
        echo "🚧 Dry run - would delete ghcr.io tag: $tag"
        echo
        continue
      fi

      echo "🌐 Delete tag $tag from ghcr.io"

      # Try user package endpoint first, then org endpoint.
      version_id=$(
        gh api "/users/$owner/packages/container/$package_name/versions" \
          --paginate \
          -q ".[] | select(.metadata.container.tags[]? == \"$tag_name\") | .id" \
          2> /dev/null \
          || gh api "/orgs/$owner/packages/container/$package_name/versions" \
            --paginate \
            -q ".[] | select(.metadata.container.tags[]? == \"$tag_name\") | .id" \
            2> /dev/null || true
      )

      if [ -z "$version_id" ]; then
        echo "⚠️ Tag $tag_name not found in $package_name, skipping"
        echo
        continue
      fi

      gh api --method DELETE \
        "/users/$owner/packages/container/$package_name/versions/$version_id" \
        2> /dev/null \
        || gh api --method DELETE \
          "/orgs/$owner/packages/container/$package_name/versions/$version_id"

      echo "➡️ $tag deleted"
      echo
    done
  fi
fi

# Delete Docker Hub tags.
if [ "${#dockerhub_tags[@]}" -gt 0 ]; then
  if [ -z "$DOCKERHUB_USERNAME" ] || [ -z "$DOCKERHUB_TOKEN" ]; then
    echo "⚠️ Docker Hub credentials not set, skipping Docker Hub cleanup"
    echo
  else
    base_url="https://hub.docker.com/v2"
    token=""

    if [ "$dry_run" = "true" ]; then
      token="placeholder"
      echo "🚧 Dry run - would call $base_url to get a token"
      echo
    else
      echo "🌐 Get token from $base_url"

      readarray -t lines < <(
        curl -s -X POST \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$DOCKERHUB_USERNAME\", \"password\":\"$DOCKERHUB_TOKEN\"}" \
          -w "\n%{http_code}" \
          "$base_url/users/login"
      )

      http_code="${lines[-1]}"
      unset 'lines[-1]'
      json_body=$(printf "%s\n" "${lines[@]}")

      if [ "$http_code" -ne "200" ]; then
        echo "❌ Wrong HTTP status - $http_code"
        echo "$json_body"
        exit 1
      fi

      token=$(jq -r '.token' <<< "$json_body")
      echo
    fi

    if [ -z "$token" ]; then
      echo "❌ No token from Docker Hub"
      exit 1
    fi

    for tag in "${dockerhub_tags[@]}"; do
      if [ "$dry_run" = "true" ]; then
        echo "🚧 Dry run - would call $base_url to delete tag $tag"
        echo
      else
        echo "🌐 Delete tag $tag"
        IFS=':' read -ra tag_parts <<< "$tag"

        readarray -t lines < <(
          curl -s -X DELETE \
            -H "Authorization: Bearer $token" \
            -w "\n%{http_code}" \
            "$base_url/repositories/${tag_parts[0]}/tags/${tag_parts[1]}/"
        )

        http_code="${lines[-1]}"
        unset 'lines[-1]'

        if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "204" ]; then
          echo "❌ Wrong HTTP status - $http_code"
          printf '%s\n' "${lines[@]}"
          exit 1
        fi

        echo "➡️ $tag deleted"
        echo
      fi
    done
  fi
fi

echo "✅ Done!"
exit 0

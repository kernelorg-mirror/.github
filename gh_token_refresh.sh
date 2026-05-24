#!/usr/bin/env bash

set -euo pipefail

GITHUB_APP_ID="$APP_ID"
GITHUB_APP_PRIVATE_KEY="$PRIVATE_KEY"
GITHUB_INSTALLATION_ID="$INSTALLATION_ID"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

if [[ -z "${GITHUB_APP_ID:-}" ]]; then
  echo "ERROR: GITHUB_APP_ID is not set" >&2
  exit 1
fi

if [[ -z "${GITHUB_APP_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: GITHUB_APP_PRIVATE_KEY is not set" >&2
  exit 1
fi

if ! echo "${GITHUB_APP_PRIVATE_KEY}" | grep -q "BEGIN.*PRIVATE KEY"; then
  echo "ERROR: GITHUB_APP_PRIVATE_KEY is not in PEM format" >&2
  exit 1
fi

base64url_encode() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

json_get() {
  local key="$1"
  local json="$2"
  echo "${json}" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" \
    | sed 's/.*:[[:space:]]*//' \
    | tr -d '"' \
    | tr -d ' '
}

generate_jwt() {
  local app_id="$1"
  local private_key="$2"

  local header
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64url_encode)

  local now
  now=$(date +%s)
  local iat=$(( now - 60 ))
  local exp=$(( iat + 600 ))

  local payload
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" \
    | base64url_encode)

  local signing_input="${header}.${payload}"

  local tmp_key
  tmp_key=$(mktemp)
  trap "rm -f '${tmp_key}'" EXIT

  echo "${private_key}" > "${tmp_key}"
  chmod 600 "${tmp_key}"

  local signature
  signature=$(printf '%s' "${signing_input}" \
    | openssl dgst -sha256 -sign "${tmp_key}" \
    | base64url_encode)

  rm -f "${tmp_key}"
  trap - EXIT

  echo "${signing_input}.${signature}"
}

get_installation_id() {
  local jwt="$1"

  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL}/app/installations")

  if [[ -z "${response}" ]]; then
    echo "ERROR: Failed to get installation list" >&2
    exit 1
  fi

  local installation_id
  installation_id=$(echo "${response}" \
    | grep -o '"id":[[:space:]]*[0-9]*' \
    | head -1 \
    | grep -o '[0-9]*')

  if [[ -z "${installation_id}" ]]; then
    echo "ERROR: Installation ID not found. Check if the app is installed somewhere" >&2
    exit 1
  fi

  echo "${installation_id}"
}

get_installation_token() {
  local jwt="$1"
  local installation_id="$2"

  local response
  response=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL}/app/installations/${installation_id}/access_tokens")

  if [[ -z "${response}" ]]; then
    echo "ERROR: Failed to get Installation Access Token (installation_id=${installation_id})" >&2
    exit 1
  fi

  local token
  token=$(json_get "token" "${response}")

  if [[ -z "${token}" ]]; then
    echo "ERROR: Could not get token from response: ${response}" >&2
    exit 1
  fi

  local expires_at
  expires_at=$(json_get "expires_at" "${response}")

  echo "token=${token}"
  echo "expires_at=${expires_at}"
}

main() {
  echo "==> Generating JWT..." >&2
  local jwt
  jwt=$(generate_jwt "${GITHUB_APP_ID}" "${GITHUB_APP_PRIVATE_KEY}")

  local installation_id
  if [[ -n "${GITHUB_INSTALLATION_ID:-}" ]]; then
    installation_id="${GITHUB_INSTALLATION_ID}"
    echo "==> Installation ID (from env): ${installation_id}" >&2
  else
    echo "==> Installation ID (API)" >&2
    installation_id=$(get_installation_id "${jwt}")
    echo "==> Installation ID: ${installation_id}" >&2
  fi

  echo "==> Fetching Installation Access Token" >&2
  local result
  result=$(get_installation_token "${jwt}" "${installation_id}")

  local token expires_at
  token=$(echo "${result}"     | grep '^token='      | cut -d= -f2-)
  expires_at=$(echo "${result}" | grep '^expires_at=' | cut -d= -f2-)

  echo "" >&2
  echo "========================================" >&2
  echo " GitHub App Installation Access Token" >&2
  echo "========================================" >&2
  # echo "TOKEN      : ${token}" >&2
  echo "TOKEN      : (success)" >&2
  echo "EXPIRES_AT : ${expires_at}" >&2
  echo "========================================" >&2
  echo "" >&2

  echo "${token}"
}

main "$@"

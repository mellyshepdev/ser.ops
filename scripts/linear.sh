#!/usr/bin/env bash
# ser.ops <-> Linear CLI.
#
# Wraps the Linear GraphQL API so tasks and agents can read and file issues
# without each one re-inventing curl payloads or handling the API key.
#
#   linear.sh whoami
#   linear.sh list [--state <name>] [--limit N]
#   linear.sh get BLA-42
#   linear.sh search "backup"
#   linear.sh create "Title" [--desc "body"] [--priority 0-4]
#   linear.sh comment BLA-42 "body"
#   linear.sh file-error <dedupe-key> "Title" "body"
#
# `file-error` is the one automation should use: it looks for an OPEN issue
# whose description carries the same dedupe marker and COMMENTS on it instead
# of opening a duplicate. A flapping task must not be able to mint hundreds of
# issues — see .claude/skills/serops-linear/SKILL.md.
#
# The API key is read from deploy/ser_ops.env and is NEVER echoed, logged, or
# passed as a command-line argument (argv is world-readable via ps).

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
ENV_FILE="${SER_OPS_ENV:-$REPO/deploy/ser_ops.env}"
API="https://api.linear.app/graphql"
UNIT="${UNIT_NAME:-unit7}"

if [ -r "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE" 2>/dev/null; set +a
fi
KEY="${LINEAR_API_KEY:-}"
TEAM_KEY="${LINEAR_TEAM_KEY:-BLA}"

if [ -z "$KEY" ]; then
    echo "linear.sh: LINEAR_API_KEY not set (looked in $ENV_FILE)" >&2
    exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "linear.sh: jq is required" >&2; exit 2; }

# gql <query> [jq-args...] — body is built by jq so every interpolated value is
# correctly JSON-escaped. Never build GraphQL payloads with printf/string concat.
#
# The query text is carried under the reserved name `__query` and stripped from
# the variables map. It must NOT collide with a caller's variable name: using
# `q` here silently deleted the caller's own $q (search, file-error), producing
# 'Variable "$q" of required type "String!" was not provided'.
gql() {
    local query=$1; shift
    local payload
    payload=$(jq -nc --arg __query "$query" "$@" \
        '{query:$__query, variables:($ARGS.named|del(.__query))}')
    curl -sS --max-time 30 -X POST "$API" \
        -H "Authorization: $KEY" -H "Content-Type: application/json" \
        -d "$payload"
}

die_on_error() {                      # reads a response on stdin, passes it through
    local resp; resp=$(cat)
    if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
        echo "linear.sh: API error:" >&2
        printf '%s' "$resp" | jq -r '.errors[].message' >&2
        exit 1
    fi
    printf '%s' "$resp"
}

team_id() {
    gql 'query($k:String!){ teams(filter:{key:{eq:$k}}, first:1){ nodes { id } } }' \
        --arg k "$TEAM_KEY" | die_on_error | jq -r '.data.teams.nodes[0].id // empty'
}

cmd=${1:-help}; shift 2>/dev/null || true

case "$cmd" in
whoami)
    gql '{ viewer { name email } teams(first:10){ nodes { key name } } }' \
        | die_on_error | jq -r '.data | "user: \(.viewer.name) <\(.viewer.email)>",
            (.teams.nodes[] | "team: \(.key)  \(.name)")'
    ;;

list)
    state=""; limit=20
    while [ $# -gt 0 ]; do
        case "$1" in
            --state) state=${2:-}; shift 2;;
            --limit) limit=${2:-20}; shift 2;;
            *) shift;;
        esac
    done
    gql 'query($k:String!,$n:Int!){ issues(first:$n, filter:{team:{key:{eq:$k}}},
           orderBy:updatedAt){ nodes { identifier title state{name} priority updatedAt } } }' \
        --arg k "$TEAM_KEY" --argjson n "$limit" \
      | die_on_error \
      | jq -r --arg s "$state" '.data.issues.nodes[]
          | select($s=="" or (.state.name|ascii_downcase)==($s|ascii_downcase))
          | "\(.identifier)  [\(.state.name)]  \(.title)"'
    ;;

get)
    id=${1:?usage: linear.sh get BLA-42}
    gql 'query($id:String!){ issue(id:$id){ identifier title description state{name}
           priority url createdAt comments(first:20){ nodes { body createdAt user{name} } } } }' \
        --arg id "$id" | die_on_error | jq -r '.data.issue
      | "\(.identifier)  [\(.state.name)]  \(.title)", .url, "", (.description // "(no description)"),
        "", "--- comments ---", (.comments.nodes[] | "[\(.createdAt)] \(.user.name // "?"): \(.body)")'
    ;;

search)
    q=${1:?usage: linear.sh search "text"}
    gql 'query($q:String!){ searchIssues(term:$q, first:20){ nodes { identifier title state{name} } } }' \
        --arg q "$q" | die_on_error \
      | jq -r '.data.searchIssues.nodes[] | "\(.identifier)  [\(.state.name)]  \(.title)"'
    ;;

create)
    title=${1:?usage: linear.sh create "Title" [--desc ...] [--priority N]}; shift
    desc=""; prio=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --desc) desc=${2:-}; shift 2;;
            --priority) prio=${2:-0}; shift 2;;
            *) shift;;
        esac
    done
    tid=$(team_id)
    [ -n "$tid" ] || { echo "linear.sh: team $TEAM_KEY not found" >&2; exit 1; }
    gql 'mutation($t:String!,$d:String,$team:String!,$p:Int){
           issueCreate(input:{title:$t, description:$d, teamId:$team, priority:$p}){
             success issue { identifier url } } }' \
        --arg t "$title" --arg d "$desc" --arg team "$tid" --argjson p "$prio" \
      | die_on_error | jq -r '.data.issueCreate.issue | "created \(.identifier)  \(.url)"'
    ;;

comment)
    id=${1:?usage: linear.sh comment BLA-42 "body"}; body=${2:?missing body}
    gql 'query($id:String!){ issue(id:$id){ id } }' --arg id "$id" \
      | die_on_error | jq -r '.data.issue.id // empty' | {
        read -r iid
        [ -n "$iid" ] || { echo "linear.sh: issue $id not found" >&2; exit 1; }
        gql 'mutation($i:String!,$b:String!){ commentCreate(input:{issueId:$i, body:$b}){ success } }' \
            --arg i "$iid" --arg b "$body" \
          | die_on_error | jq -r 'if .data.commentCreate.success then "commented on '"$id"'" else "comment failed" end'
      }
    ;;

file-error)
    # file-error <dedupe-key> <title> <body>
    # Dedupe marker is embedded in the description so a later search finds it.
    dkey=${1:?usage: linear.sh file-error <dedupe-key> "Title" "body"}
    title=${2:?missing title}; body=${3:-}
    marker="serops-dedupe:$dkey"
    existing=$(gql 'query($q:String!){ searchIssues(term:$q, first:10){
                      nodes { identifier id state{ type } } } }' --arg q "$marker" \
               | die_on_error \
               | jq -r '[.data.searchIssues.nodes[] | select(.state.type!="completed" and .state.type!="canceled")][0].id // empty')
    if [ -n "$existing" ]; then
        gql 'mutation($i:String!,$b:String!){ commentCreate(input:{issueId:$i, body:$b}){ success } }' \
            --arg i "$existing" \
            --arg b "**recurrence on $UNIT** $(date -u +%Y-%m-%dT%H:%M:%SZ)

$body" \
          | die_on_error >/dev/null
        echo "deduped: commented on existing open issue for '$dkey'"
    else
        tid=$(team_id)
        gql 'mutation($t:String!,$d:String!,$team:String!){
               issueCreate(input:{title:$t, description:$d, teamId:$team, priority:2}){
                 success issue { identifier url } } }' \
            --arg t "$title" --arg team "$tid" \
            --arg d "$body

---
unit: $UNIT
first seen: $(date -u +%Y-%m-%dT%H:%M:%SZ)
$marker" \
          | die_on_error | jq -r '.data.issueCreate.issue | "filed \(.identifier)  \(.url)"'
    fi
    ;;

help|*)
    sed -n '3,20p' "$0"
    ;;
esac

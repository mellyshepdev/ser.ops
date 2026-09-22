#!/usr/bin/env bash
# ==============================================================================
# ser.ops config-file collector
#
# Walks every reachable unit, pulls configuration files, and upserts them into
# the config_files.files table in comms-db on unit7. This is the piece that was
# missing when unit8 died: compose files survived in compose-stacks but every
# bind-mounted config (synapse homeserver.yaml, mailserver accounts, .env
# files) existed only on the dead disk.
#
# Idempotent: rows are keyed (unit, path) and only rewritten when sha256
# changes, so the daily loop can run it cheaply.
#
# Store includes .env contents on purpose -- the DB is the DR vault. It sits
# on comms-db, reachable only over the tailnet.
# ==============================================================================
set -uo pipefail

PSQL="docker exec -i comms-db psql -U postgres -d config_files -v ON_ERROR_STOP=1 -q"
LOCK=/tmp/backup-configs.lock
exec 9>"$LOCK"
flock -n 9 || { echo "backup-configs already running"; exit 0; }

# --- unit targets ------------------------------------------------------------
UNITS=(
  "unit7|local"
  "unit2|ssh -o BatchMode=yes -o ConnectTimeout=8 unit2"
  "unit3|ssh -o BatchMode=yes -o ConnectTimeout=8 -i $HOME/.ssh/id_ed25519 swoopggainz@100.78.95.13"
  "unit6|ssh -o BatchMode=yes -o ConnectTimeout=8 -i $HOME/.ssh/id_ed25519 swoopg111@100.66.180.60"
  "unit9|ssh -o BatchMode=yes -o ConnectTimeout=8 -i $HOME/.ssh/id_ed25519_mesh root@100.94.170.118"
)

# Directories searched on each unit, relative to ~
SEARCH_DIRS="projects server stacks compose-stacks"

# Single-quoted so neither local nor remote shell glob-expands them.
REMOTE_FIND='find DIR -type f \( -name "docker-compose*.yml" -o -name "docker-compose*.yaml" -o -name "*.env" -o -name "*.conf" -o -name "homeserver.yaml" -o -name "*.cfg" -o -name "postfix-accounts.cf" -o -name "*.yml" -o -name "*.yaml" \) -size -1048576c 2>/dev/null'

sqlq() { printf "%s" "$1" | sed "s/'/''/g"; }

total_new=0
for entry in "${UNITS[@]}"; do
  unit="${entry%%|*}"
  target="${entry#*|}"
  echo "=== $unit ==="

  paths=""
  for d in $SEARCH_DIRS; do
    if [ "$target" = "local" ]; then
      [ -d "$HOME/$d" ] || continue
      found=$(eval "${REMOTE_FIND/DIR/\"$HOME/$d\"}")
    else
      found=$($target "[ -d \$HOME/$d ] && ${REMOTE_FIND/DIR/\$HOME/$d}" 2>/dev/null)
    fi
    [ -n "$found" ] && paths="$paths
$found"
  done
  paths=$(printf '%s\n' "$paths" | sed '/^$/d' | sort -u)

  if [ -z "$paths" ]; then
    echo "  unreachable or empty - skipped"
    continue
  fi

  n=0; upd=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    n=$((n+1))
    tmp=$(mktemp)
    if [ "$target" = "local" ]; then
      cat "$p" > "$tmp" 2>/dev/null
    else
      $target "cat \"$p\"" > "$tmp" < /dev/null 2>/dev/null
    fi
    if [ ! -s "$tmp" ]; then rm -f "$tmp"; continue; fi

    sha=$(sha256sum "$tmp" | cut -d' ' -f1)
    sp=$(sqlq "$p")
    dup=$($PSQL -tAc "SELECT count(*) FROM files WHERE unit='$(sqlq "$unit")' AND path='$sp' AND sha256='$sha'" < /dev/null 2>/dev/null || echo 0)
    if [ "$dup" = "0" ]; then
      {
        printf "INSERT INTO files(unit,path,sha256,content,fetched_at) VALUES ('%s','%s','%s','" "$(sqlq "$unit")" "$sp" "$sha"
        sed "s/'/''/g" "$tmp"
        printf "',now()) ON CONFLICT (unit,path) DO UPDATE SET sha256=EXCLUDED.sha256, content=EXCLUDED.content, fetched_at=now();"
      } | $PSQL && upd=$((upd+1))
    fi
    rm -f "$tmp"
  done <<< "$paths"

  echo "  scanned $n files, stored $upd new/changed"
  total_new=$((total_new+upd))
done

echo "done: $total_new new/changed config files stored"
$PSQL -c "SELECT unit, count(*), max(fetched_at) AS latest FROM files GROUP BY unit ORDER BY unit"

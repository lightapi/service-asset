#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./update-asset.sh [options]

Rebuild and refresh service-asset contents from local workspace projects.

Options:
  -f, --force          Rebuild portal-view, login-view, and event-importer even
                      when source signatures have not changed.
  --skip-service       Do not call ../copy-service-local.sh.
  --skip-compose-stop  Do not stop local portal-config-loc Docker Compose stacks.
  --skip-db-init-sync  Do not sync portal-config-loc postgres-db/init.sql.
  --skip-snapshot      Do not refresh events.json from event-store/snapshot.
  --commit-and-push    Commit service-asset changes and push them to GitHub
                       after a successful update.
  --commit-message MSG Commit message used with --commit-and-push.
  -h, --help           Show this help.

Environment overrides:
  WORKSPACE_DIR              Default: parent directory of service-asset
  COPY_SERVICE_LOCAL         Default: $WORKSPACE_DIR/copy-service-local.sh
  PORTAL_VIEW_DIR            Default: $WORKSPACE_DIR/portal-view
  LOGIN_VIEW_DIR             Default: first existing login-view/signin-view path
  EVENT_IMPORTER_DIR         Default: $WORKSPACE_DIR/event-importer
  EVENT_EXPORTER_DIR         Default: $WORKSPACE_DIR/event-exporter
  LIGHT_PORTAL_DIR           Default: $WORKSPACE_DIR/light-portal
  PORTAL_DB_DIR              Default: $WORKSPACE_DIR/portal-db
  PORTAL_VIEW_BUILD_CMD      Default: npm run build
  LOGIN_VIEW_BUILD_CMD       Default: npm run build
  PORTAL_VIEW_INSTALL_CMD    Default: npm ci
  LOGIN_VIEW_INSTALL_CMD     Default: npm ci
  SKIP_NPM_INSTALL           Default: false; set true to require existing deps
  EVENT_IMPORTER_BUILD_CMD   Default: mvn -q -DskipTests package
  EVENT_EXPORTER_BUILD_CMD   Default: mvn -q -DskipTests package
  LOCAL_PORTAL_CONFIG_DIRS   Colon-separated portal-config-loc paths to stop.
                             Default: ~/lightapi/portal-config-loc and
                             $WORKSPACE_DIR/portal-config-loc when present.
  PORTAL_CONFIG_LOC_DIRS     Colon-separated portal-config-loc paths whose
                             postgres-db/init.sql should be synced. Defaults
                             to LOCAL_PORTAL_CONFIG_DIRS or the same built-in
                             paths as local compose shutdown.
  SKIP_LOGIN_VIEW            Default: false; set true to skip if absent
  REQUIRE_LOGIN_VIEW         Default: false; set true to fail if absent
  EVENT_EXPORT_DB_READY_TIMEOUT
                             Default: 90 seconds to wait for local Postgres
                             before running event-exporter.
  EVENT_EXPORT_DB_READY_INTERVAL
                             Default: 3 seconds between Postgres checks.
  EVENT_EXPORTER_IMAGE       Default: networknt/event-exporter:latest
  EVENT_IMPORTER_IMAGE       Default: networknt/event-importer:latest
  USE_DOCKER_TOOLS           Default: auto. Values: auto, true, false.
                             auto uses Docker images when they exist locally.
  EVENT_CONVERTER_RUNNER     Default: local. Values: local, docker, auto.
                             local uses the freshly built event-importer jar for
                             snapshot-to-events conversion; docker/auto use the
                             EVENT_IMPORTER_IMAGE when available/required.
  TOOL_DOCKER_NETWORK        Optional Docker network for one-shot tool
                             containers. Default: first restarted Compose
                             project network, or all-in-lt_default.
  PORTAL_EXPORT_READY_TIMEOUT
                             Default: 180 seconds to wait for portal/query
                             after restarting Docker Compose.
  PORTAL_EXPORT_READY_INTERVAL
                             Default: 5 seconds between readiness checks.
  PORTAL_EXPORT_READY_URL    Default: https://localhost:8440/health. This waits
                             for the local hybrid-query backend to accept TLS
                             before exporting through PORTAL_API_BASE_URL.

Events export/conversion:
  EVENT_EXPORT_SOURCE        Default: snapshot. Values:
                               snapshot   DB-backed global snapshot export via
                                          event-exporter --snapshot, then
                                          event-importer --convert.
                               events     event-store history export via
                                          event-exporter.
                               portal-api existing portal query snapshot API,
                                          then event-importer --convert.
  EVENT_EXPORT_START         Default: 1970-01-01T00:00:00Z
  EVENT_EXPORT_END           Optional; defaults to current UTC in exporter.sh
  EVENT_EXPORT_PORTAL_SERVICES
                             Optional comma-separated portal services for
                             event-exporter -p.
  EVENT_EXPORT_AGGREGATE_TYPES
                             Optional comma-separated aggregate types for
                             event-exporter -a.
  EVENT_EXPORT_EVENT_TYPES   Optional comma-separated event types for
                             event-exporter -t.
  EVENT_EXPORT_HOST_ID       Optional host id filter for event-exporter -o.
  PORTAL_API_BASE_URL        Default: https://local.lightapi.net
  PORTAL_INSECURE           Default: true; passes -k to curl
  PORTAL_COOKIE             Optional Cookie header value for authenticated calls
  PORTAL_AUTH_HEADER         Optional full auth header, for example:
                             'Authorization: Bearer ...'
  SOURCE_HOST_ID            Default: 01964b05-552a-7c4b-9184-6857e7f3dc5f
  TARGET_HOST_ID            Default: SOURCE_HOST_ID
  ADMIN_USER_ID             Default: 01964b05-5532-7c79-8cde-191dcbd421b8
  EXPORT_SCOPE              Default: both
  ENTITY_TYPES_JSON         Optional JSON array passed as entityTypes
  SNAPSHOT_INPUT            Optional existing snapshot JSON; skips API export
  SNAPSHOT_OUTPUT           Optional path to keep the exported snapshot JSON
  EVENTS_OUTPUT             Default: $SERVICE_ASSET_DIR/events.json
  BUILD_STATE_FILE          Default: $SERVICE_ASSET_DIR/build-time.txt
  COMPOSE_STATE_FILE        Default: $SERVICE_ASSET_DIR/.update-asset-compose-state
  GIT_COMMIT_AND_PUSH       Default: false. Set true to commit and push after
                             a successful update.
  GIT_COMMIT_MESSAGE        Default: Update service assets YYYY-MM-DD HH:MM UTC
  GIT_REMOTE                Default: origin
  GIT_BRANCH                Default: current branch
  PORTAL_COMPOSE_START_DIR  Fallback Compose directory to start before export
                             when no stopped stack was recorded. Default: first
                             existing all-in-lt under LOCAL_PORTAL_CONFIG_DIRS,
                             ~/lightapi/portal-config-loc, or workspace.
  PORTAL_COMPOSE_START_PROFILE
                             Default: all-in-lt.
  PORTAL_COMPOSE_START_ARGS Default: -f docker-compose.yml -f docker-compose-rust.yml
USAGE
}

log() {
  printf '[update-asset] %s\n' "$*"
}

warn() {
  printf '[update-asset] warning: %s\n' "$*" >&2
}

die() {
  printf '[update-asset] error: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found in PATH"
}

run_in_dir() {
  local dir="$1"
  local command_text="$2"

  [[ -d "$dir" ]] || die "directory not found: $dir"
  log "running in $dir: $command_text"
  (cd "$dir" && bash -lc "$command_text")
}

ensure_node_dependencies() {
  local dir="$1"
  local label="$2"
  local install_cmd="$3"

  [[ -f "$dir/package.json" ]] || die "$label package.json not found: $dir/package.json"

  if [[ -d "$dir/node_modules" ]]; then
    return 0
  fi

  if is_true "${SKIP_NPM_INSTALL:-false}"; then
    die "$label node_modules is missing and SKIP_NPM_INSTALL is true: $dir/node_modules"
  fi

  log "$label node_modules missing; installing dependencies"
  run_in_dir "$dir" "$install_cmd"
}

copy_dist() {
  local src_dir="$1"
  local dst_dir="$2"
  local label="$3"

  [[ -d "$src_dir" ]] || die "$label dist directory not found: $src_dir"
  [[ -f "$src_dir/index.html" ]] || die "$label dist is missing index.html: $src_dir"

  mkdir -p "$(dirname -- "$dst_dir")"
  rm -rf "$dst_dir"
  cp -a "$src_dir" "$dst_dir"
  log "copied $label dist to $dst_dir"
}

read_state() {
  local key="$1"

  [[ -f "$BUILD_STATE_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$BUILD_STATE_FILE"
}

git_head() {
  local repo_dir="$1"

  if [[ -d "$repo_dir/.git" ]]; then
    git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || true
  fi
}

repo_signature() {
  local repo_dir="$1"

  [[ -d "$repo_dir/.git" ]] || {
    printf 'missing\n'
    return 0
  }

  (
    cd "$repo_dir"
    git ls-files -co --exclude-standard -z |
      while IFS= read -r -d '' rel_path; do
        case "$rel_path" in
          .git/*|node_modules/*|dist/*|dist-ssr/*|target/*|build/*|coverage/*|logs/*)
            continue
            ;;
          *.log|*.tmp)
            continue
            ;;
        esac

        [[ -f "$rel_path" ]] || continue
        file_hash="$(sha256sum "$rel_path" | awk '{print $1}')"
        printf '%s  %s\n' "$file_hash" "$rel_path"
      done |
      sort |
      sha256sum |
      awk '{print $1}'
  )
}

should_rebuild() {
  local label="$1"
  local current_signature="$2"
  local previous_signature="$3"

  if [[ "$force" == true ]]; then
    log "$label rebuild forced"
    return 0
  fi

  if [[ -z "$previous_signature" ]]; then
    log "$label has no previous build signature"
    return 0
  fi

  if [[ "$current_signature" != "$previous_signature" ]]; then
    log "$label source signature changed"
    return 0
  fi

  log "$label source signature unchanged; skipping rebuild"
  return 1
}

has_running_compose_containers() {
  local compose_dir="$1"
  local project_name

  compose_dir="$(cd "$compose_dir" && pwd)"
  project_name="$(basename "$compose_dir")"
  docker ps \
    --filter "label=com.docker.compose.project=$project_name" \
    --filter "label=com.docker.compose.project.working_dir=$compose_dir" \
    --format "{{.Names}}" |
    grep -q .
}

detect_running_compose_args_from_label() {
  local compose_dir="$1"
  local project_name
  local config_files
  local compose_files=()
  local file
  local rel_file
  local args=()

  compose_dir="$(cd "$compose_dir" && pwd)"
  project_name="$(basename "$compose_dir")"
  config_files="$(
    docker ps \
      --filter "label=com.docker.compose.project=$project_name" \
      --filter "label=com.docker.compose.project.working_dir=$compose_dir" \
      --format '{{.Label "com.docker.compose.project.config_files"}}' |
      awk 'NF { print; exit }'
  )"

  [[ -n "$config_files" ]] || return 0

  IFS=',' read -r -a compose_files <<< "$config_files"
  for file in "${compose_files[@]}"; do
    [[ -n "$file" ]] || continue

    if [[ "$file" == "$compose_dir/"* ]]; then
      rel_file="${file#$compose_dir/}"
    else
      rel_file="$file"
    fi

    if [[ -f "$compose_dir/$rel_file" || -f "$file" ]]; then
      args+=("-f" "$rel_file")
    fi
  done

  ((${#args[@]})) || return 0
  printf '%s\n' "${args[*]}"
}

detect_running_compose_args_from_services() {
  local compose_dir="$1"
  local project_name
  local running

  compose_dir="$(cd "$compose_dir" && pwd)"
  project_name="$(basename "$compose_dir")"
  running="$(
    docker ps \
      --filter "label=com.docker.compose.project=$project_name" \
      --filter "label=com.docker.compose.project.working_dir=$compose_dir" \
      --format '{{.Label "com.docker.compose.service"}} {{.Image}}'
  )"

  [[ -n "$running" ]] || return 0

  case "$running" in
    *light-agent*|*light-workflow*|*demo-customer-profile-api*|*demo-offer-decision-api*|*controller-rs*)
      printf '%s\n' "-f docker-compose.yml -f docker-compose-rust.yml"
      return 0
      ;;
    *light-controller*|*oauth-kafka*|*light-reference*|*config-server:*-java*|*light-gateway:2.2.1*)
      printf '%s\n' "-f docker-compose.yml -f docker-compose-java.yml"
      return 0
      ;;
  esac
}

record_stopped_compose_stack() {
  local compose_dir="$1"
  local compose_args="$2"
  local key="$compose_dir|$compose_args"
  local existing

  for existing in "${stopped_compose_keys[@]:-}"; do
    [[ "$existing" != "$key" ]] || return 0
  done

  stopped_compose_keys+=("$key")
  stopped_compose_dirs+=("$compose_dir")
  stopped_compose_args+=("$compose_args")
}

write_stopped_compose_state() {
  local tmp_state="$tmp_dir/stopped-compose-state"
  local index

  ((${#stopped_compose_dirs[@]})) || return 0

  mkdir -p "$(dirname -- "$COMPOSE_STATE_FILE")"
  : > "$tmp_state"
  for index in "${!stopped_compose_dirs[@]}"; do
    printf '%s\t%s\n' "${stopped_compose_dirs[$index]}" "${stopped_compose_args[$index]}" >> "$tmp_state"
  done
  cp "$tmp_state" "$COMPOSE_STATE_FILE"
}

load_stopped_compose_state() {
  local compose_dir
  local compose_args

  [[ -f "$COMPOSE_STATE_FILE" ]] || return 0

  while IFS=$'\t' read -r compose_dir compose_args || [[ -n "$compose_dir" ]]; do
    [[ -n "$compose_dir" && -n "$compose_args" ]] || continue
    [[ -d "$compose_dir" ]] || continue
    record_stopped_compose_stack "$compose_dir" "$compose_args"
  done < "$COMPOSE_STATE_FILE"
}

clear_stopped_compose_state() {
  [[ -f "$COMPOSE_STATE_FILE" ]] || return 0
  rm -f "$COMPOSE_STATE_FILE"
}

stop_compose_project() {
  local compose_dir="$1"
  local fallback_args="$2"
  local compose_args

  [[ -d "$compose_dir" ]] || return 0
  [[ -f "$compose_dir/docker-compose.yml" ]] || return 0

  compose_dir="$(cd "$compose_dir" && pwd)"

  if ! has_running_compose_containers "$compose_dir"; then
    log "no running Docker Compose containers found for $(basename "$compose_dir")"
    return 0
  fi

  compose_args="$(detect_running_compose_args_from_label "$compose_dir")"
  if [[ -z "$compose_args" ]]; then
    compose_args="$(detect_running_compose_args_from_services "$compose_dir")"
  fi
  if [[ -z "$compose_args" ]]; then
    compose_args="$fallback_args"
    warn "could not detect Compose files for $compose_dir; using fallback: $compose_args"
  fi

  record_stopped_compose_stack "$compose_dir" "$compose_args"
  write_stopped_compose_state
  log "stopping Docker Compose stack in $compose_dir"
  (
    cd "$compose_dir"
    docker compose $compose_args down --timeout 30 --remove-orphans
  )
}

stop_local_compose_stacks() {
  local roots=()
  local root

  require_command docker
  docker compose version >/dev/null 2>&1 || die "docker compose is required to stop local stacks"

  if [[ -n "${LOCAL_PORTAL_CONFIG_DIRS:-}" ]]; then
    IFS=':' read -r -a roots <<< "$LOCAL_PORTAL_CONFIG_DIRS"
  else
    roots=("${HOME:-}/lightapi/portal-config-loc" "$WORKSPACE_DIR/portal-config-loc")
  fi

  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] || continue

    stop_compose_project "$root/all-in-one" "-f docker-compose.yml"
    stop_compose_project "$root/all-in-pg" "-f docker-compose.yml -f docker-compose-rust.yml"
    stop_compose_project "$root/all-in-lt" "-f docker-compose.yml -f docker-compose-rust.yml"
  done
}

restart_stopped_compose_stacks() {
  local index
  local compose_dir
  local compose_args

  if ((${#stopped_compose_dirs[@]} == 0)); then
    load_stopped_compose_state
  fi

  if ((${#stopped_compose_dirs[@]} == 0)); then
    if start_fallback_portal_compose_stack; then
      return 0
    fi
    log "no Docker Compose stacks were stopped or stored by this run"
    return 0
  fi

  for index in "${!stopped_compose_dirs[@]}"; do
    compose_dir="${stopped_compose_dirs[$index]}"
    compose_args="${stopped_compose_args[$index]}"

    log "restarting Docker Compose stack in $compose_dir"
    (
      cd "$compose_dir"
      docker compose $compose_args up -d
    )
  done

  clear_stopped_compose_state
}

default_portal_compose_start_dir() {
  local roots_raw
  local roots=()
  local root
  local profile="${PORTAL_COMPOSE_START_PROFILE:-all-in-lt}"

  if [[ -n "${LOCAL_PORTAL_CONFIG_DIRS:-}" ]]; then
    roots_raw="$LOCAL_PORTAL_CONFIG_DIRS"
  else
    roots_raw="${HOME:-}/lightapi/portal-config-loc:$WORKSPACE_DIR/portal-config-loc"
  fi

  IFS=':' read -r -a roots <<< "$roots_raw"
  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    [[ -d "$root/$profile" ]] || continue
    [[ -f "$root/$profile/docker-compose.yml" ]] || continue
    printf '%s\n' "$root/$profile"
    return 0
  done
}

start_fallback_portal_compose_stack() {
  local compose_dir="${PORTAL_COMPOSE_START_DIR:-$(default_portal_compose_start_dir)}"
  local compose_args="${PORTAL_COMPOSE_START_ARGS:--f docker-compose.yml -f docker-compose-rust.yml}"

  [[ -n "$compose_dir" ]] || return 1
  [[ -d "$compose_dir" ]] || die "PORTAL_COMPOSE_START_DIR not found: $compose_dir"
  [[ -f "$compose_dir/docker-compose.yml" ]] || die "docker-compose.yml not found in PORTAL_COMPOSE_START_DIR: $compose_dir"

  log "starting fallback Docker Compose stack in $compose_dir"
  (
    cd "$compose_dir"
    docker compose $compose_args up -d
  )
}

wait_for_portal_query() {
  local ready_url="$PORTAL_EXPORT_READY_URL"
  local timeout="$PORTAL_EXPORT_READY_TIMEOUT"
  local interval="$PORTAL_EXPORT_READY_INTERVAL"
  local elapsed=0
  local http_code
  local curl_args=(-sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 5)

  require_command curl

  if is_true "$PORTAL_INSECURE"; then
    curl_args=(-k "${curl_args[@]}")
  fi

  log "waiting up to ${timeout}s for $ready_url"
  while ((elapsed <= timeout)); do
    http_code="$(curl "${curl_args[@]}" "$ready_url" 2>/dev/null || true)"
    if [[ -n "$http_code" && "$http_code" != "000" && "$http_code" -lt 500 ]]; then
      log "portal export backend is ready (HTTP $http_code)"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  die "portal export backend did not become ready within ${timeout}s: $ready_url"
}

default_portal_config_roots() {
  if [[ -n "${LOCAL_PORTAL_CONFIG_DIRS:-}" ]]; then
    printf '%s\n' "$LOCAL_PORTAL_CONFIG_DIRS"
  else
    printf '%s:%s\n' "${HOME:-}/lightapi/portal-config-loc" "$WORKSPACE_DIR/portal-config-loc"
  fi
}

sync_postgres_init_sql() {
  local roots_raw
  local roots=()
  local generated_init="$tmp_dir/init.sql"
  local root
  local profile
  local dest

  [[ -f "$PORTAL_DB_DIR/postgres/ddl.sql" ]] || die "portal-db ddl.sql not found: $PORTAL_DB_DIR/postgres/ddl.sql"
  [[ -f "$PORTAL_DB_DIR/postgres/sp_tr_fn.sql" ]] || die "portal-db sp_tr_fn.sql not found: $PORTAL_DB_DIR/postgres/sp_tr_fn.sql"
  [[ -f "$PORTAL_DB_DIR/postgres/init-lightapi.sql" ]] || die "portal-db init-lightapi.sql not found: $PORTAL_DB_DIR/postgres/init-lightapi.sql"

  {
    printf 'CREATE DATABASE configserver;\n'
    printf '\\c configserver;\n\n'
    cat "$PORTAL_DB_DIR/postgres/ddl.sql"
    printf '\n\n'
    cat "$PORTAL_DB_DIR/postgres/sp_tr_fn.sql"
    printf '\n\n'
    cat "$PORTAL_DB_DIR/postgres/init-lightapi.sql"
  } > "$generated_init"

  roots_raw="${PORTAL_CONFIG_LOC_DIRS:-$(default_portal_config_roots)}"
  IFS=':' read -r -a roots <<< "$roots_raw"

  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] || continue

    for profile in all-in-one all-in-pg all-in-lt; do
      dest="$root/$profile/postgres-db/init.sql"
      [[ -d "$(dirname -- "$dest")" ]] || continue

      if [[ -f "$dest" ]] && cmp -s "$generated_init" "$dest"; then
        log "postgres init.sql already current: $dest"
        continue
      fi

      cp "$generated_init" "$dest"
      log "synced postgres init.sql from portal-db to $dest"
    done
  done
}

write_snapshot_payload() {
  local output_file="$1"

  require_command node
  node - "$output_file" "$SOURCE_HOST_ID" "$EXPORT_SCOPE" "${ENTITY_TYPES_JSON:-}" <<'NODE'
const fs = require('fs');

const [outputFile, sourceHostId, exportScope, entityTypesJson] = process.argv.slice(2);
const params = {
  sourceHostId,
  exportScope,
};

if (entityTypesJson) {
  params.entityTypes = JSON.parse(entityTypesJson);
}

const payload = {
  jsonrpc: '2.0',
  method: 'lightapi.net/user/exportGlobalSnapshot/0.1.0',
  params,
  id: `update-asset-${Date.now()}`,
};

fs.writeFileSync(outputFile, `${JSON.stringify(payload)}\n`);
NODE
}

unwrap_json_rpc_response() {
  local input_file="$1"
  local output_file="$2"

  require_command node
  node - "$input_file" "$output_file" <<'NODE'
const fs = require('fs');

const [inputFile, outputFile] = process.argv.slice(2);
const raw = fs.readFileSync(inputFile, 'utf8');
let value = JSON.parse(raw);

if (value && value.jsonrpc === '2.0') {
  if (value.error) {
    const message = typeof value.error === 'string'
      ? value.error
      : JSON.stringify(value.error);
    throw new Error(message);
  }
  value = value.result;
}

if (typeof value === 'string') {
  try {
    value = JSON.parse(value);
  } catch {
    fs.writeFileSync(outputFile, value.endsWith('\n') ? value : `${value}\n`);
    process.exit(0);
  }
}

fs.writeFileSync(outputFile, `${JSON.stringify(value, null, 2)}\n`);
NODE
}

export_global_snapshot() {
  local snapshot_file="$1"
  local payload_file="$tmp_dir/export-global-snapshot-request.json"
  local response_file="$tmp_dir/export-global-snapshot-response.json"
  local curl_stderr="$tmp_dir/export-global-snapshot-curl.stderr"
  local query_url="${PORTAL_API_BASE_URL%/}/portal/query"
  local http_code
  local curl_args=()

  require_command curl
  write_snapshot_payload "$payload_file"

  curl_args=(-sS -X POST "$query_url" -H "Content-Type: application/json" --data-binary "@$payload_file")

  if is_true "$PORTAL_INSECURE"; then
    curl_args=(-k "${curl_args[@]}")
  fi

  if [[ -n "${PORTAL_COOKIE:-}" ]]; then
    curl_args+=(-H "Cookie: $PORTAL_COOKIE")
  fi

  if [[ -n "${PORTAL_AUTH_HEADER:-}" ]]; then
    curl_args+=(-H "$PORTAL_AUTH_HEADER")
  fi

  if [[ -z "${PORTAL_AUTH_HEADER:-}" && -z "${PORTAL_COOKIE:-}" ]]; then
    warn "snapshot export requires a user Authorization Code token; set PORTAL_AUTH_HEADER or PORTAL_COOKIE"
  fi

  log "exporting $EXPORT_SCOPE snapshot from $query_url"
  if ! http_code="$(curl "${curl_args[@]}" -o "$response_file" -w "%{http_code}" 2>"$curl_stderr")"; then
    [[ ! -s "$curl_stderr" ]] || sed -n '1,20p' "$curl_stderr" >&2
    die "snapshot export request failed before receiving a valid HTTP response from $query_url"
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    warn "snapshot export returned HTTP $http_code"
    [[ ! -s "$response_file" ]] || sed -n '1,20p' "$response_file" >&2
    die "snapshot export failed: $query_url"
  fi

  unwrap_json_rpc_response "$response_file" "$snapshot_file"
  log "wrote snapshot to $snapshot_file"
}

convert_snapshot_to_events() {
  local snapshot_file="$1"
  local events_file="$2"
  local converted_file="$tmp_dir/events.json"
  local snapshot_dir
  local snapshot_name
  local events_dir
  local events_name

  mkdir -p "$(dirname -- "$events_file")"

  if should_use_docker_converter; then
    snapshot_dir="$(cd "$(dirname -- "$snapshot_file")" && pwd)"
    snapshot_name="$(basename -- "$snapshot_file")"
    events_dir="$(cd "$(dirname -- "$events_file")" && pwd)"
    events_name="$(basename -- "$events_file")"

    log "converting snapshot to events.json through Docker event-importer"
    run_docker_tool "$EVENT_IMPORTER_IMAGE" \
      -v "$snapshot_dir:/snapshot:ro" \
      -v "$events_dir:/out" \
      -- \
      --convert \
      --filename "/snapshot/$snapshot_name" \
      --targetHostId "$TARGET_HOST_ID" \
      --adminUserId "$ADMIN_USER_ID" \
      --output "/out/$events_name"
    [[ -f "$events_file" ]] || die "event-importer did not create events file: $events_file"
    log "copied converted events to $events_file"
    return 0
  fi

  [[ -x "$EVENT_IMPORTER_DIR/converter.sh" ]] || die "converter script not executable: $EVENT_IMPORTER_DIR/converter.sh"
  if [[ ! -f "$EVENT_IMPORTER_DIR/target/event-importer.jar" ]] ||
    find "$EVENT_IMPORTER_DIR/src" "$EVENT_IMPORTER_DIR/pom.xml" -newer "$EVENT_IMPORTER_DIR/target/event-importer.jar" -print -quit | grep -q .; then
    log "event-importer jar missing or stale; building it"
    run_in_dir "$EVENT_IMPORTER_DIR" "$EVENT_IMPORTER_BUILD_CMD"
  fi
  [[ -f "$EVENT_IMPORTER_DIR/target/event-importer.jar" ]] || die "event-importer jar not found: $EVENT_IMPORTER_DIR/target/event-importer.jar"

  log "converting snapshot to events.json"
  "$EVENT_IMPORTER_DIR/converter.sh" \
    --filename "$snapshot_file" \
    --targetHostId "$TARGET_HOST_ID" \
    --adminUserId "$ADMIN_USER_ID" \
    --output "$converted_file"

  cp "$converted_file" "$events_file"
  log "copied converted events to $events_file"
}

append_snapshot_events() {
  local events_file="$1"
  local snapshot_events_file="$tmp_dir/snapshot_events.json"
  local final_events_file="$tmp_dir/final_events.json"
  local host_id="${EVENT_EXPORT_HOST_ID:-$SOURCE_HOST_ID}"
  local args=(-s "1970-01-01T00:00:00.000Z" -t ConfigSnapshotCreatedEvent)

  require_command jq

  if [[ -n "$host_id" ]]; then
    args+=(-o "$host_id")
  fi

  if [[ -n "${EVENT_EXPORT_END:-}" ]]; then
    args+=(-e "$EVENT_EXPORT_END")
  fi

  if should_use_docker_tool "$EVENT_EXPORTER_IMAGE"; then
    log "exporting ConfigSnapshotCreatedEvent through Docker event-exporter"
    local events_dir="$(cd "$(dirname -- "$snapshot_events_file")" && pwd)"
    local events_name="$(basename -- "$snapshot_events_file")"
    run_docker_tool "$EVENT_EXPORTER_IMAGE" \
      -v "$events_dir:/out" \
      -- \
      "${args[@]}" \
      -f "/out/$events_name"
  else
    ensure_event_exporter_jar
    log "exporting ConfigSnapshotCreatedEvent"
    (cd "$EVENT_EXPORTER_DIR" && ./exporter.sh "${args[@]}" -f "$snapshot_events_file")
  fi

  if [[ -f "$snapshot_events_file" ]]; then
    log "filtering and appending snapshot events to events.json"
    jq -s '.[0] + (.[1] | map(select(.data.current == true)) | sort_by(.data.hostId, .data.instanceId, .time, .id) | group_by([.data.hostId, .data.instanceId]) | map(last))' "$events_file" "$snapshot_events_file" > "$final_events_file"
    mv "$final_events_file" "$events_file"
  else
    die "event-exporter did not create snapshot events file: $snapshot_events_file"
  fi
}

wait_for_local_postgres() {
  local timeout="${EVENT_EXPORT_DB_READY_TIMEOUT:-90}"
  local interval="${EVENT_EXPORT_DB_READY_INTERVAL:-3}"
  local elapsed=0

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker command not found; skipping local Postgres readiness check"
    return 0
  fi

  log "waiting up to ${timeout}s for local Postgres"
  while ((elapsed <= timeout)); do
    if docker exec postgres pg_isready -U postgres -d configserver >/dev/null 2>&1; then
      log "local Postgres is ready"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  warn "local Postgres did not report ready within ${timeout}s; event-exporter will attempt JDBC connection"
}

default_tool_docker_network() {
  if [[ -n "${TOOL_DOCKER_NETWORK:-}" ]]; then
    printf '%s\n' "$TOOL_DOCKER_NETWORK"
    return 0
  fi

  if ((${#stopped_compose_dirs[@]} == 0)); then
    load_stopped_compose_state
  fi

  if ((${#stopped_compose_dirs[@]} > 0)); then
    printf '%s_default\n' "$(basename "${stopped_compose_dirs[0]}")"
    return 0
  fi

  printf 'all-in-lt_default\n'
}

should_use_docker_tool() {
  local image="$1"

  case "$USE_DOCKER_TOOLS" in
    true)
      require_command docker
      docker image inspect "$image" >/dev/null 2>&1 || die "Docker image not found: $image"
      return 0
      ;;
    false)
      return 1
      ;;
    auto)
      command -v docker >/dev/null 2>&1 || return 1
      docker image inspect "$image" >/dev/null 2>&1
      ;;
    *)
      die "USE_DOCKER_TOOLS must be auto, true, or false: $USE_DOCKER_TOOLS"
      ;;
  esac
}

should_use_docker_converter() {
  case "$EVENT_CONVERTER_RUNNER" in
    local)
      return 1
      ;;
    docker)
      docker image inspect "$EVENT_IMPORTER_IMAGE" >/dev/null 2>&1 || die "Docker image not found: $EVENT_IMPORTER_IMAGE"
      return 0
      ;;
    auto)
      docker image inspect "$EVENT_IMPORTER_IMAGE" >/dev/null 2>&1
      ;;
    *)
      die "EVENT_CONVERTER_RUNNER must be local, docker, or auto: $EVENT_CONVERTER_RUNNER"
      ;;
  esac
}

run_docker_tool() {
  local image="$1"
  shift
  local network
  local docker_args=()

  network="$(default_tool_docker_network)"
  while (($#)); do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    docker_args+=("$1")
    shift
  done

  log "running Docker tool $image on network $network"
  docker run --rm --network "$network" -u "$(id -u):$(id -g)" "${docker_args[@]}" "$image" "$@"
}

ensure_event_exporter_jar() {
  local event_exporter_script="$EVENT_EXPORTER_DIR/exporter.sh"
  local event_exporter_jar="$EVENT_EXPORTER_DIR/target/event-exporter.jar"

  [[ -d "$EVENT_EXPORTER_DIR" ]] || die "event-exporter directory not found: $EVENT_EXPORTER_DIR"
  [[ -x "$event_exporter_script" ]] || die "event-exporter script not executable: $event_exporter_script"

  if [[ ! -f "$event_exporter_jar" ]] ||
    find "$EVENT_EXPORTER_DIR/src" "$EVENT_EXPORTER_DIR/pom.xml" -newer "$event_exporter_jar" -print -quit | grep -q .; then
    log "event-exporter jar missing or stale; building it"
    run_in_dir "$EVENT_EXPORTER_DIR" "$EVENT_EXPORTER_BUILD_CMD"
  fi
  [[ -f "$event_exporter_jar" ]] || die "event-exporter jar not found: $event_exporter_jar"
}

export_snapshot_with_event_exporter() {
  local snapshot_file="$1"
  local snapshot_dir
  local snapshot_name
  local args=(--snapshot --sourceHostId "$SOURCE_HOST_ID" --exportScope "$EXPORT_SCOPE")

  if [[ -n "${ENTITY_TYPES_JSON:-}" ]]; then
    require_command node
    args+=(--entityTypes "$(node -e "const v=JSON.parse(process.argv[1]); console.log(Array.isArray(v) ? v.join(',') : '')" "$ENTITY_TYPES_JSON")")
  fi

  if should_use_docker_tool "$EVENT_EXPORTER_IMAGE"; then
    snapshot_dir="$(cd "$(dirname -- "$snapshot_file")" && pwd)"
    snapshot_name="$(basename -- "$snapshot_file")"
    run_docker_tool "$EVENT_EXPORTER_IMAGE" \
      -v "$snapshot_dir:/out" \
      -- \
      "${args[@]}" \
      -f "/out/$snapshot_name"
  else
    ensure_event_exporter_jar
    (cd "$EVENT_EXPORTER_DIR" && ./exporter.sh "${args[@]}" -f "$snapshot_file")
  fi

  [[ -f "$snapshot_file" ]] || die "event-exporter did not create snapshot file: $snapshot_file"
  log "wrote snapshot to $snapshot_file"
}

export_events_from_event_store() {
  local events_file="$1"
  local events_dir
  local events_name
  local args=(-f "$events_file" -s "$EVENT_EXPORT_START")

  [[ -n "$EVENT_EXPORT_START" ]] || die "EVENT_EXPORT_START must not be empty"
  [[ "$EVENT_EXPORT_START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}(:[0-9]{2})?)$ ]] ||
    die "EVENT_EXPORT_START is not valid ISO 8601: $EVENT_EXPORT_START"

  if [[ -n "${EVENT_EXPORT_END:-}" ]]; then
    [[ "$EVENT_EXPORT_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}(:[0-9]{2})?)$ ]] ||
      die "EVENT_EXPORT_END is not valid ISO 8601: $EVENT_EXPORT_END"
    args+=(-e "$EVENT_EXPORT_END")
  fi

  if [[ -n "${EVENT_EXPORT_PORTAL_SERVICES:-}" ]]; then
    args+=(-p "$EVENT_EXPORT_PORTAL_SERVICES")
  fi
  if [[ -n "${EVENT_EXPORT_AGGREGATE_TYPES:-}" ]]; then
    args+=(-a "$EVENT_EXPORT_AGGREGATE_TYPES")
  fi
  if [[ -n "${EVENT_EXPORT_EVENT_TYPES:-}" ]]; then
    args+=(-t "$EVENT_EXPORT_EVENT_TYPES")
  fi
  if [[ -n "${EVENT_EXPORT_HOST_ID:-}" ]]; then
    args+=(-o "$EVENT_EXPORT_HOST_ID")
  fi

  mkdir -p "$(dirname -- "$events_file")"
  log "exporting events from event_store_t through event-exporter"
  if should_use_docker_tool "$EVENT_EXPORTER_IMAGE"; then
    events_dir="$(cd "$(dirname -- "$events_file")" && pwd)"
    events_name="$(basename -- "$events_file")"
    args[1]="/out/$events_name"
    run_docker_tool "$EVENT_EXPORTER_IMAGE" \
      -v "$events_dir:/out" \
      -- \
      "${args[@]}"
  else
    ensure_event_exporter_jar
    (cd "$EVENT_EXPORTER_DIR" && ./exporter.sh "${args[@]}")
  fi

  [[ -f "$events_file" ]] || die "event-exporter did not create events file: $events_file"
  log "wrote events to $events_file"
}

write_build_state() {
  local output_file="$BUILD_STATE_FILE"
  local tmp_state="$tmp_dir/build-time.txt"
  local completed_at

  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '# Generated by update-asset.sh after a successful run.\n'
    printf 'last_successful_build_time=%s\n' "$completed_at"
    printf 'previous_successful_build_time=%s\n' "$previous_build_time"
    printf 'service_asset_head=%s\n' "$(git_head "$SERVICE_ASSET_DIR")"
    printf 'portal_view_dir=%s\n' "$PORTAL_VIEW_DIR"
    printf 'portal_view_head=%s\n' "$(git_head "$PORTAL_VIEW_DIR")"
    printf 'portal_view_signature=%s\n' "$portal_view_signature"
    printf 'login_view_dir=%s\n' "${LOGIN_VIEW_DIR:-}"
    printf 'login_view_head=%s\n' "${login_view_head:-}"
    printf 'login_view_signature=%s\n' "${login_view_signature:-}"
    printf 'light_portal_dir=%s\n' "$LIGHT_PORTAL_DIR"
    printf 'light_portal_head=%s\n' "$(git_head "$LIGHT_PORTAL_DIR")"
    printf 'light_portal_signature=%s\n' "$light_portal_signature"
    printf 'event_importer_dir=%s\n' "$EVENT_IMPORTER_DIR"
    printf 'event_importer_head=%s\n' "$(git_head "$EVENT_IMPORTER_DIR")"
    printf 'event_importer_signature=%s\n' "$event_importer_signature"
    printf 'event_export_source=%s\n' "$EVENT_EXPORT_SOURCE"
    printf 'event_exporter_dir=%s\n' "${EVENT_EXPORTER_DIR:-}"
    printf 'event_exporter_head=%s\n' "${event_exporter_head:-}"
    printf 'event_export_start=%s\n' "${EVENT_EXPORT_START:-}"
    printf 'event_export_end=%s\n' "${EVENT_EXPORT_END:-}"
    printf 'portal_db_dir=%s\n' "$PORTAL_DB_DIR"
    printf 'portal_db_head=%s\n' "$(git_head "$PORTAL_DB_DIR")"
    printf 'portal_db_signature=%s\n' "$portal_db_signature"
    printf 'source_host_id=%s\n' "$SOURCE_HOST_ID"
    printf 'target_host_id=%s\n' "$TARGET_HOST_ID"
    printf 'admin_user_id=%s\n' "$ADMIN_USER_ID"
    printf 'export_scope=%s\n' "$EXPORT_SCOPE"
    printf 'events_output=%s\n' "$EVENTS_OUTPUT"
  } > "$tmp_state"

  cp "$tmp_state" "$output_file"
  log "updated build record $output_file"
}

commit_and_push_service_asset() {
  local remote="${GIT_REMOTE:-origin}"
  local branch="${GIT_BRANCH:-}"
  local commit_message="${GIT_COMMIT_MESSAGE:-}"

  [[ -d "$SERVICE_ASSET_DIR/.git" ]] || die "service-asset is not a git worktree: $SERVICE_ASSET_DIR"

  if [[ -z "$branch" ]]; then
    branch="$(git -C "$SERVICE_ASSET_DIR" rev-parse --abbrev-ref HEAD)"
  fi
  [[ -n "$branch" && "$branch" != "HEAD" ]] || die "cannot push from detached HEAD; set GIT_BRANCH"

  if [[ -z "$commit_message" ]]; then
    commit_message="Update service assets $(date -u '+%Y-%m-%d %H:%M UTC')"
  fi

  if git -C "$SERVICE_ASSET_DIR" diff --quiet && git -C "$SERVICE_ASSET_DIR" diff --cached --quiet &&
    [[ -z "$(git -C "$SERVICE_ASSET_DIR" ls-files --others --exclude-standard)" ]]; then
    log "service-asset worktree is clean; nothing to commit"
    return 0
  fi

  log "staging service-asset changes"
  git -C "$SERVICE_ASSET_DIR" add -A

  if git -C "$SERVICE_ASSET_DIR" diff --cached --quiet; then
    log "no staged service-asset changes; nothing to commit"
    return 0
  fi

  log "committing service-asset changes"
  git -C "$SERVICE_ASSET_DIR" commit -m "$commit_message"

  log "pushing service-asset commit to $remote/$branch"
  git -C "$SERVICE_ASSET_DIR" push "$remote" "HEAD:$branch"
}

force=false
skip_service=false
skip_compose_stop=false
skip_db_init_sync=false
skip_snapshot=false
commit_and_push=false
stopped_compose_keys=()
stopped_compose_dirs=()
stopped_compose_args=()

while (($#)); do
  case "$1" in
    -f|--force)
      force=true
      ;;
    --skip-service)
      skip_service=true
      ;;
    --skip-compose-stop)
      skip_compose_stop=true
      ;;
    --skip-db-init-sync)
      skip_db_init_sync=true
      ;;
    --skip-snapshot)
      skip_snapshot=true
      ;;
    --commit-and-push)
      commit_and_push=true
      ;;
    --commit-message)
      [[ $# -ge 2 ]] || die "--commit-message requires a value"
      GIT_COMMIT_MESSAGE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

SERVICE_ASSET_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd -- "$SERVICE_ASSET_DIR/.." && pwd)}"
COPY_SERVICE_LOCAL="${COPY_SERVICE_LOCAL:-$WORKSPACE_DIR/copy-service-local.sh}"
PORTAL_VIEW_DIR="${PORTAL_VIEW_DIR:-$WORKSPACE_DIR/portal-view}"
EVENT_IMPORTER_DIR="${EVENT_IMPORTER_DIR:-$WORKSPACE_DIR/event-importer}"
EVENT_EXPORTER_DIR="${EVENT_EXPORTER_DIR:-$WORKSPACE_DIR/event-exporter}"
LIGHT_PORTAL_DIR="${LIGHT_PORTAL_DIR:-$WORKSPACE_DIR/light-portal}"
PORTAL_DB_DIR="${PORTAL_DB_DIR:-$WORKSPACE_DIR/portal-db}"

if [[ -z "${LOGIN_VIEW_DIR:-}" ]]; then
  for candidate in "$WORKSPACE_DIR/login-view" "$WORKSPACE_DIR/signin-view"; do
    if [[ -d "$candidate" ]]; then
      LOGIN_VIEW_DIR="$candidate"
      break
    fi
  done
fi

PORTAL_VIEW_BUILD_CMD="${PORTAL_VIEW_BUILD_CMD:-npm run build}"
LOGIN_VIEW_BUILD_CMD="${LOGIN_VIEW_BUILD_CMD:-npm run build}"
PORTAL_VIEW_INSTALL_CMD="${PORTAL_VIEW_INSTALL_CMD:-npm ci}"
LOGIN_VIEW_INSTALL_CMD="${LOGIN_VIEW_INSTALL_CMD:-npm ci}"
EVENT_IMPORTER_BUILD_CMD="${EVENT_IMPORTER_BUILD_CMD:-mvn -q -DskipTests package}"
EVENT_EXPORTER_BUILD_CMD="${EVENT_EXPORTER_BUILD_CMD:-mvn -q -DskipTests package}"
EVENT_EXPORT_SOURCE="${EVENT_EXPORT_SOURCE:-snapshot}"
EVENT_EXPORT_START="${EVENT_EXPORT_START:-1970-01-01T00:00:00Z}"
EVENT_EXPORTER_IMAGE="${EVENT_EXPORTER_IMAGE:-networknt/event-exporter:latest}"
EVENT_IMPORTER_IMAGE="${EVENT_IMPORTER_IMAGE:-networknt/event-importer:latest}"
USE_DOCKER_TOOLS="${USE_DOCKER_TOOLS:-auto}"
EVENT_CONVERTER_RUNNER="${EVENT_CONVERTER_RUNNER:-local}"
PORTAL_API_BASE_URL="${PORTAL_API_BASE_URL:-https://local.lightapi.net}"
PORTAL_INSECURE="${PORTAL_INSECURE:-true}"
EVENT_EXPORT_DB_READY_TIMEOUT="${EVENT_EXPORT_DB_READY_TIMEOUT:-90}"
EVENT_EXPORT_DB_READY_INTERVAL="${EVENT_EXPORT_DB_READY_INTERVAL:-3}"
PORTAL_EXPORT_READY_TIMEOUT="${PORTAL_EXPORT_READY_TIMEOUT:-180}"
PORTAL_EXPORT_READY_INTERVAL="${PORTAL_EXPORT_READY_INTERVAL:-5}"
PORTAL_EXPORT_READY_URL="${PORTAL_EXPORT_READY_URL:-https://localhost:8440/health}"
SOURCE_HOST_ID="${SOURCE_HOST_ID:-01964b05-552a-7c4b-9184-6857e7f3dc5f}"
TARGET_HOST_ID="${TARGET_HOST_ID:-$SOURCE_HOST_ID}"
ADMIN_USER_ID="${ADMIN_USER_ID:-01964b05-5532-7c79-8cde-191dcbd421b8}"
EXPORT_SCOPE="${EXPORT_SCOPE:-both}"
EVENTS_OUTPUT="${EVENTS_OUTPUT:-$SERVICE_ASSET_DIR/events.json}"
BUILD_STATE_FILE="${BUILD_STATE_FILE:-$SERVICE_ASSET_DIR/build-time.txt}"
COMPOSE_STATE_FILE="${COMPOSE_STATE_FILE:-$SERVICE_ASSET_DIR/.update-asset-compose-state}"
GIT_COMMIT_AND_PUSH="${GIT_COMMIT_AND_PUSH:-false}"

if is_true "$GIT_COMMIT_AND_PUSH"; then
  commit_and_push=true
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/update-asset.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

require_command git
require_command sha256sum
require_command sort
require_command awk

[[ -d "$PORTAL_VIEW_DIR" ]] || die "portal-view directory not found: $PORTAL_VIEW_DIR"
[[ -d "$EVENT_IMPORTER_DIR" ]] || die "event-importer directory not found: $EVENT_IMPORTER_DIR"
[[ -d "$LIGHT_PORTAL_DIR" ]] || die "light-portal directory not found: $LIGHT_PORTAL_DIR"
[[ -d "$PORTAL_DB_DIR" ]] || die "portal-db directory not found: $PORTAL_DB_DIR"

case "$EVENT_EXPORT_SOURCE" in
  event-exporter)
    warn "EVENT_EXPORT_SOURCE=event-exporter is deprecated; using events"
    EVENT_EXPORT_SOURCE="events"
    ;;
  snapshot|events|portal-api)
    ;;
  *)
    die "EVENT_EXPORT_SOURCE must be snapshot, events, or portal-api: $EVENT_EXPORT_SOURCE"
    ;;
esac

if [[ "$skip_snapshot" == false && "$EVENT_EXPORT_SOURCE" != "portal-api" && -z "${SNAPSHOT_INPUT:-}" ]]; then
  [[ -d "$EVENT_EXPORTER_DIR" ]] || die "event-exporter directory not found: $EVENT_EXPORTER_DIR"
fi

if [[ ! -d "${LOGIN_VIEW_DIR:-}" ]]; then
  if is_true "${REQUIRE_LOGIN_VIEW:-false}"; then
    die "login-view directory not found; set LOGIN_VIEW_DIR or disable REQUIRE_LOGIN_VIEW"
  fi
  if ! is_true "${SKIP_LOGIN_VIEW:-false}"; then
    warn "login-view directory not found; set LOGIN_VIEW_DIR to rebuild signin/dist"
  fi
  LOGIN_VIEW_DIR=""
fi

previous_build_time="$(read_state last_successful_build_time)"
previous_portal_view_signature="$(read_state portal_view_signature)"
previous_login_view_signature="$(read_state login_view_signature)"
previous_light_portal_signature="$(read_state light_portal_signature)"
previous_event_importer_signature="$(read_state event_importer_signature)"

portal_view_signature="$(repo_signature "$PORTAL_VIEW_DIR")"
light_portal_signature="$(repo_signature "$LIGHT_PORTAL_DIR")"
event_importer_signature="$(repo_signature "$EVENT_IMPORTER_DIR")"
portal_db_signature="$(repo_signature "$PORTAL_DB_DIR")"
event_exporter_head="$(git_head "$EVENT_EXPORTER_DIR")"

if [[ -n "$LOGIN_VIEW_DIR" ]]; then
  login_view_signature="$(repo_signature "$LOGIN_VIEW_DIR")"
  login_view_head="$(git_head "$LOGIN_VIEW_DIR")"
else
  login_view_signature=""
  login_view_head=""
fi

log "using workspace: $WORKSPACE_DIR"
log "using service-asset: $SERVICE_ASSET_DIR"
log "previous successful build: ${previous_build_time:-none}"

if [[ "$skip_db_init_sync" == false ]]; then
  sync_postgres_init_sql
else
  log "skipping postgres init.sql sync"
fi

if [[ "$skip_service" == false ]]; then
  [[ -x "$COPY_SERVICE_LOCAL" ]] || die "copy-service-local.sh not executable: $COPY_SERVICE_LOCAL"
  if [[ "$skip_compose_stop" == false ]]; then
    stop_local_compose_stacks
  else
    log "skipping local Docker Compose shutdown"
  fi
  log "rebuilding and copying backend service jars"
  "$COPY_SERVICE_LOCAL" --force
else
  log "skipping backend service jar refresh"
fi

if should_rebuild "portal-view" "$portal_view_signature" "$previous_portal_view_signature"; then
  ensure_node_dependencies "$PORTAL_VIEW_DIR" "portal-view" "$PORTAL_VIEW_INSTALL_CMD"
  run_in_dir "$PORTAL_VIEW_DIR" "$PORTAL_VIEW_BUILD_CMD"
  copy_dist "$PORTAL_VIEW_DIR/dist" "$SERVICE_ASSET_DIR/lightapi/dist" "portal-view"
fi

if [[ -n "$LOGIN_VIEW_DIR" ]]; then
  if should_rebuild "login-view" "$login_view_signature" "$previous_login_view_signature"; then
    ensure_node_dependencies "$LOGIN_VIEW_DIR" "login-view" "$LOGIN_VIEW_INSTALL_CMD"
    run_in_dir "$LOGIN_VIEW_DIR" "$LOGIN_VIEW_BUILD_CMD"
    copy_dist "$LOGIN_VIEW_DIR/dist" "$SERVICE_ASSET_DIR/signin/dist" "login-view"
  fi
else
  log "skipping login-view rebuild"
fi

if should_rebuild "event-importer" \
  "${light_portal_signature}:${event_importer_signature}" \
  "${previous_light_portal_signature}:${previous_event_importer_signature}"; then
  run_in_dir "$EVENT_IMPORTER_DIR" "$EVENT_IMPORTER_BUILD_CMD"
  mkdir -p "$SERVICE_ASSET_DIR/target"
  cp "$EVENT_IMPORTER_DIR/target/event-importer.jar" "$SERVICE_ASSET_DIR/target/event-importer.jar"
  log "copied event-importer.jar to $SERVICE_ASSET_DIR/target/event-importer.jar"
fi

if [[ "$skip_snapshot" == false ]]; then
  snapshot_file="${SNAPSHOT_INPUT:-${SNAPSHOT_OUTPUT:-$tmp_dir/global-snapshot.json}}"
  if [[ -n "${SNAPSHOT_INPUT:-}" ]]; then
    [[ -f "$snapshot_file" ]] || die "snapshot input not found: $snapshot_file"
    log "using existing snapshot input: $snapshot_file"
    convert_snapshot_to_events "$snapshot_file" "$EVENTS_OUTPUT"
  else
    if [[ "$skip_compose_stop" == false ]]; then
      restart_stopped_compose_stacks
    fi
    if [[ "$EVENT_EXPORT_SOURCE" == "snapshot" ]]; then
      wait_for_local_postgres
      export_snapshot_with_event_exporter "$snapshot_file"
      convert_snapshot_to_events "$snapshot_file" "$EVENTS_OUTPUT"
      append_snapshot_events "$EVENTS_OUTPUT"
    elif [[ "$EVENT_EXPORT_SOURCE" == "events" ]]; then
      wait_for_local_postgres
      export_events_from_event_store "$EVENTS_OUTPUT"
    else
      wait_for_portal_query
      export_global_snapshot "$snapshot_file"
      convert_snapshot_to_events "$snapshot_file" "$EVENTS_OUTPUT"
    fi
  fi
else
  log "skipping events.json refresh"
fi

write_build_state

if [[ "$commit_and_push" == true ]]; then
  commit_and_push_service_asset
else
  log "skipping service-asset git commit/push"
fi

log "asset update completed successfully"

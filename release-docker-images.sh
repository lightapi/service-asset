#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./release-docker-images.sh [options]

Build and publish a coherent batch of Docker images with one immutable tag.

Options:
  --tag TAG             Docker tag to use for this batch. If omitted, the
                        script uses BASE_VERSION-dev.YYYYMMDD.HHMM in UTC.
  --base-version VER    Base version used for the generated tag. Default: 2.3.5.
  --profile PROFILE     Image set to release. Default: lt-rust.
                        Profiles: lt-rust, java, all-in-one, hybrid, portal,
                        rust-apps, admin-tools.
  --component NAME      Release one component. Can be repeated. Overrides
                        --profile. Use --list to show component names.
  --local               Build locally but do not push.
  --dry-run             Print the plan without building, stopping Compose, or
                        pushing images.
  --push-latest         Also push the moving latest tags created by build.sh.
  --skip-compose-stop   Do not stop local portal-config-loc Docker Compose stacks.
  --no-compose-env      Do not write the compose image env file.
  --no-cache            Pass --no-cache to build scripts that support it.
  --list                Show profiles and components.
  -h, --help            Show this help.

Environment overrides:
  WORKSPACE_DIR             Default: parent directory of service-asset
  LOCAL_PORTAL_CONFIG_DIRS  Colon-separated portal-config-loc paths to stop.
                            Default: ~/lightapi/portal-config-loc and
                            $WORKSPACE_DIR/portal-config-loc when present.
  COMPOSE_ENV_OUT           Default: $SERVICE_ASSET_DIR/docker-images.env
  BASE_VERSION              Default: 2.3.5

Notes:
  The script calls existing repo build.sh files with --local, then pushes only
  the exact tags it just built. This avoids docker push -a from legacy scripts.
USAGE
}

log() {
  printf '[release-docker-images] %s\n' "$*"
}

die() {
  printf '[release-docker-images] error: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  local workdir="$1"
  shift

  if [[ "$dry_run" == true ]]; then
    printf '[release-docker-images] would run in %s:' "$workdir"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  (cd "$workdir" && "$@")
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found in PATH"
}

component_path() {
  case "$1" in
    hybrid-command) printf '%s/hybrid-command\n' "$WORKSPACE_DIR" ;;
    hybrid-query) printf '%s/hybrid-query\n' "$WORKSPACE_DIR" ;;
    portal-service) printf '%s/portal-service\n' "$WORKSPACE_DIR" ;;
    controller-rs) printf '%s/controller-rs\n' "$WORKSPACE_DIR" ;;
    light-agent) printf '%s/light-fabric/apps/light-agent\n' "$WORKSPACE_DIR" ;;
    light-workflow) printf '%s/light-fabric/apps/light-workflow\n' "$WORKSPACE_DIR" ;;
    light-gateway-rs) printf '%s/light-fabric/apps/light-gateway\n' "$WORKSPACE_DIR" ;;
    demo-customer-profile-api) printf '%s/light-example-rs\n' "$WORKSPACE_DIR" ;;
    demo-offer-decision-api) printf '%s/light-example-rs\n' "$WORKSPACE_DIR" ;;
    light-controller) printf '%s/light-controller\n' "$WORKSPACE_DIR" ;;
    oauth-kafka) printf '%s/oauth-kafka\n' "$WORKSPACE_DIR" ;;
    config-server-java) printf '%s/light-config-server\n' "$WORKSPACE_DIR" ;;
    light-reference) printf '%s/light-reference\n' "$WORKSPACE_DIR" ;;
    light-gateway-java) printf '%s/light-gateway\n' "$WORKSPACE_DIR" ;;
    openapi-petstore) printf '%s/openapi-petstore\n' "$WORKSPACE_DIR" ;;
    http-sidecar) printf '%s/http-sidecar\n' "$WORKSPACE_DIR" ;;
    event-exporter) printf '%s/event-exporter\n' "$WORKSPACE_DIR" ;;
    event-importer) printf '%s/event-importer\n' "$WORKSPACE_DIR" ;;
    *) return 1 ;;
  esac
}

append_push_tag() {
  PUSH_TAGS+=("$1")
}

append_latest_tag() {
  LATEST_TAGS+=("$1")
}

register_env_line() {
  ENV_LINES+=("$1=$2")
}

build_args_for_supported_no_cache() {
  if [[ "$no_cache" == true ]]; then
    printf '%s\n' "--no-cache"
  fi
}

build_component() {
  local component="$1"
  local dir
  local no_cache_arg=()

  dir="$(component_path "$component")" || die "unknown component: $component"
  [[ -d "$dir" ]] || die "component directory not found for $component: $dir"
  case "$component" in
    event-exporter|event-importer)
      [[ -f "$dir/Dockerfile" ]] || die "Dockerfile not found for $component: $dir/Dockerfile"
      ;;
    *)
      [[ -x "$dir/build.sh" ]] || die "build script not executable for $component: $dir/build.sh"
      ;;
  esac

  log "building component $component with tag $release_tag"

  case "$component" in
    hybrid-command)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/portal-hybrid-command:$release_tag"
      append_push_tag "networknt/portal-hybrid-command:$release_tag-slim"
      append_latest_tag "networknt/portal-hybrid-command:latest"
      register_env_line "PORTAL_HYBRID_COMMAND_IMAGE" "networknt/portal-hybrid-command:$release_tag"
      ;;
    hybrid-query)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/portal-hybrid-query:$release_tag"
      append_push_tag "networknt/portal-hybrid-query:$release_tag-slim"
      append_latest_tag "networknt/portal-hybrid-query:latest"
      register_env_line "PORTAL_HYBRID_QUERY_IMAGE" "networknt/portal-hybrid-query:$release_tag"
      ;;
    portal-service)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local "${no_cache_arg[@]}"
      append_push_tag "networknt/config-server:$release_tag"
      append_push_tag "networknt/light-oauth:$release_tag"
      append_push_tag "networknt/portal-service:$release_tag"
      append_latest_tag "networknt/config-server:latest"
      append_latest_tag "networknt/light-oauth:latest"
      append_latest_tag "networknt/portal-service:latest"
      register_env_line "CONFIG_SERVER_IMAGE" "networknt/config-server:$release_tag"
      register_env_line "LIGHT_OAUTH_IMAGE" "networknt/light-oauth:$release_tag"
      register_env_line "PORTAL_SERVICE_IMAGE" "networknt/portal-service:$release_tag"
      ;;
    controller-rs)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local "${no_cache_arg[@]}"
      append_push_tag "networknt/controller-rs:$release_tag"
      append_latest_tag "networknt/controller-rs:latest"
      register_env_line "CONTROLLER_RS_IMAGE" "networknt/controller-rs:$release_tag"
      ;;
    light-agent)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local "${no_cache_arg[@]}"
      append_push_tag "networknt/light-agent:$release_tag"
      append_latest_tag "networknt/light-agent:latest"
      register_env_line "LIGHT_AGENT_IMAGE" "networknt/light-agent:$release_tag"
      ;;
    light-workflow)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local "${no_cache_arg[@]}"
      append_push_tag "networknt/light-workflow:$release_tag"
      append_latest_tag "networknt/light-workflow:latest"
      register_env_line "LIGHT_WORKFLOW_IMAGE" "networknt/light-workflow:$release_tag"
      ;;
    light-gateway-rs)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local "${no_cache_arg[@]}"
      append_push_tag "networknt/light-gateway:$release_tag"
      append_latest_tag "networknt/light-gateway:latest"
      register_env_line "LIGHT_GATEWAY_IMAGE" "networknt/light-gateway:$release_tag"
      ;;
    demo-customer-profile-api)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local --app demo-customer-profile-api "${no_cache_arg[@]}"
      append_push_tag "networknt/demo-customer-profile-api:$release_tag"
      append_latest_tag "networknt/demo-customer-profile-api:latest"
      register_env_line "DEMO_CUSTOMER_PROFILE_API_IMAGE" "networknt/demo-customer-profile-api:$release_tag"
      ;;
    demo-offer-decision-api)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" ./build.sh "$release_tag" --local --app demo-offer-decision-api "${no_cache_arg[@]}"
      append_push_tag "networknt/demo-offer-decision-api:$release_tag"
      append_latest_tag "networknt/demo-offer-decision-api:latest"
      register_env_line "DEMO_OFFER_DECISION_API_IMAGE" "networknt/demo-offer-decision-api:$release_tag"
      ;;
    light-controller)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/light-controller:$release_tag"
      append_push_tag "networknt/light-controller:$release_tag-slim"
      append_latest_tag "networknt/light-controller:latest"
      register_env_line "LIGHT_CONTROLLER_IMAGE" "networknt/light-controller:$release_tag"
      ;;
    oauth-kafka)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/oauth-kafka:$release_tag"
      append_push_tag "networknt/oauth-kafka:$release_tag-slim"
      append_latest_tag "networknt/oauth-kafka:latest"
      register_env_line "OAUTH_KAFKA_IMAGE" "networknt/oauth-kafka:$release_tag"
      ;;
    config-server-java)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/config-server:$release_tag-java"
      append_push_tag "networknt/config-server:$release_tag-slim"
      register_env_line "CONFIG_SERVER_JAVA_IMAGE" "networknt/config-server:$release_tag-java"
      ;;
    light-reference)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/light-reference:$release_tag"
      append_push_tag "networknt/light-reference:$release_tag-slim"
      append_latest_tag "networknt/light-reference:latest"
      register_env_line "LIGHT_REFERENCE_IMAGE" "networknt/light-reference:$release_tag"
      ;;
    light-gateway-java)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/light-gateway:$release_tag"
      append_push_tag "networknt/light-gateway:$release_tag-slim"
      append_latest_tag "networknt/light-gateway:latest"
      register_env_line "LIGHT_GATEWAY_IMAGE" "networknt/light-gateway:$release_tag"
      ;;
    openapi-petstore)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/openapi-petstore:$release_tag"
      append_push_tag "networknt/openapi-petstore:$release_tag-slim"
      append_latest_tag "networknt/openapi-petstore:latest"
      register_env_line "OPENAPI_PETSTORE_IMAGE" "networknt/openapi-petstore:$release_tag"
      ;;
    http-sidecar)
      run_cmd "$dir" ./build.sh "$release_tag" --local
      append_push_tag "networknt/http-sidecar:$release_tag"
      append_push_tag "networknt/http-sidecar:$release_tag-slim"
      append_latest_tag "networknt/http-sidecar:latest"
      register_env_line "HTTP_SIDECAR_IMAGE" "networknt/http-sidecar:$release_tag"
      ;;
    event-exporter)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" mvn -q -DskipTests package
      run_cmd "$dir" docker build "${no_cache_arg[@]}" -t "networknt/event-exporter:$release_tag" -t "networknt/event-exporter:latest" .
      append_push_tag "networknt/event-exporter:$release_tag"
      append_latest_tag "networknt/event-exporter:latest"
      register_env_line "EVENT_EXPORTER_IMAGE" "networknt/event-exporter:$release_tag"
      ;;
    event-importer)
      mapfile -t no_cache_arg < <(build_args_for_supported_no_cache)
      run_cmd "$dir" mvn -q -DskipTests package
      run_cmd "$dir" docker build "${no_cache_arg[@]}" -t "networknt/event-importer:$release_tag" -t "networknt/event-importer:latest" .
      append_push_tag "networknt/event-importer:$release_tag"
      append_latest_tag "networknt/event-importer:latest"
      register_env_line "EVENT_IMPORTER_IMAGE" "networknt/event-importer:$release_tag"
      ;;
  esac
}

profile_components() {
  case "$1" in
    lt-rust)
      printf '%s\n' \
        hybrid-command hybrid-query portal-service controller-rs light-agent \
        light-workflow light-gateway-rs demo-customer-profile-api demo-offer-decision-api \
        event-exporter event-importer
      ;;
    java)
      printf '%s\n' \
        hybrid-command hybrid-query light-controller oauth-kafka config-server-java \
        light-reference light-gateway-java
      ;;
    all-in-one)
      printf '%s\n' \
        hybrid-command hybrid-query oauth-kafka config-server-java light-reference \
        light-gateway-java openapi-petstore http-sidecar
      ;;
    hybrid)
      printf '%s\n' hybrid-command hybrid-query
      ;;
    portal)
      printf '%s\n' portal-service
      ;;
    rust-apps)
      printf '%s\n' controller-rs light-agent light-workflow light-gateway-rs \
        demo-customer-profile-api demo-offer-decision-api
      ;;
    admin-tools)
      printf '%s\n' event-exporter event-importer
      ;;
    *)
      return 1
      ;;
  esac
}

list_profiles_and_components() {
  cat <<'LIST'
Profiles:
  lt-rust      Local LT Rust stack: hybrid, portal-service, Rust controller/gateway/agent/workflow, demos.
  java         Java controller/oauth/config/reference/gateway plus hybrid images.
  all-in-one   Kafka/all-in-one Java stack images plus hybrid images.
  hybrid       portal-hybrid-command and portal-hybrid-query only.
  portal       config-server, light-oauth, portal-service from portal-service repo.
  rust-apps    Rust controller/gateway/agent/workflow and demo APIs.
  admin-tools  event-exporter and event-importer utility images.

Components:
  hybrid-command
  hybrid-query
  portal-service
  controller-rs
  light-agent
  light-workflow
  light-gateway-rs
  demo-customer-profile-api
  demo-offer-decision-api
  light-controller
  oauth-kafka
  config-server-java
  light-reference
  light-gateway-java
  openapi-petstore
  http-sidecar
  event-exporter
  event-importer
LIST
}

has_compose_containers() {
  local compose_dir="$1"
  local project_name

  project_name="$(basename "$compose_dir")"
  docker ps --all \
    --filter "label=com.docker.compose.project=$project_name" \
    --format "{{.Names}}" |
    grep -q .
}

stop_compose_stack() {
  local compose_dir="$1"
  shift

  [[ -d "$compose_dir" ]] || return 0
  [[ -f "$compose_dir/docker-compose.yml" ]] || return 0

  if [[ "$dry_run" == true ]]; then
    log "would inspect and stop Docker Compose stack in $compose_dir"
    return 0
  fi

  if ! has_compose_containers "$compose_dir"; then
    log "no Docker Compose containers found for $(basename "$compose_dir")"
    return 0
  fi

  log "stopping Docker Compose stack in $compose_dir"
  (
    cd "$compose_dir"
    docker compose "$@" down --timeout 30 --remove-orphans
  )
}

stop_local_compose_stacks() {
  local roots=()
  local root

  if [[ "$dry_run" == false ]]; then
    require_command docker
    docker compose version >/dev/null 2>&1 || die "docker compose is required to stop local stacks"
  fi

  if [[ -n "${LOCAL_PORTAL_CONFIG_DIRS:-}" ]]; then
    IFS=':' read -r -a roots <<< "$LOCAL_PORTAL_CONFIG_DIRS"
  else
    roots=("${HOME:-}/lightapi/portal-config-loc" "$WORKSPACE_DIR/portal-config-loc")
  fi

  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] || continue

    stop_compose_stack "$root/all-in-one" -f docker-compose.yml
    stop_compose_stack "$root/all-in-one" -f docker-compose.yml -f docker-compose-kafka.yml
    stop_compose_stack "$root/all-in-pg" -f docker-compose.yml -f docker-compose-java.yml
    stop_compose_stack "$root/all-in-pg" -f docker-compose.yml -f docker-compose-rust.yml
    stop_compose_stack "$root/all-in-lt" -f docker-compose.yml -f docker-compose-java.yml
    stop_compose_stack "$root/all-in-lt" -f docker-compose.yml -f docker-compose-rust.yml
  done
}

push_tags() {
  local tag

  if [[ "$local_only" == true ]]; then
    log "local mode enabled; skipping Docker Hub push"
    return 0
  fi

  require_command docker

  for tag in "${PUSH_TAGS[@]}"; do
    if [[ "$dry_run" == true ]]; then
      log "would push $tag"
    else
      docker push "$tag"
    fi
  done

  if [[ "$push_latest" == true ]]; then
    for tag in "${LATEST_TAGS[@]}"; do
      if [[ "$dry_run" == true ]]; then
        log "would push $tag"
      else
        docker push "$tag"
      fi
    done
  fi
}

write_compose_env() {
  local output="$COMPOSE_ENV_OUT"
  local tmp_file
  local line

  [[ "$write_compose_env_file" == true ]] || return 0

  if [[ "$dry_run" == true ]]; then
    log "would write compose image env file to $output"
    for line in "${ENV_LINES[@]}"; do
      printf '[release-docker-images]   %s\n' "$line"
    done
    return 0
  fi

  mkdir -p "$(dirname -- "$output")"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/docker-images-env.XXXXXX")"
  {
    printf '# Generated by release-docker-images.sh\n'
    printf '# tag=%s\n' "$release_tag"
    for line in "${ENV_LINES[@]}"; do
      printf '%s\n' "$line"
    done
  } > "$tmp_file"
  mv "$tmp_file" "$output"
  log "wrote compose image env file to $output"
}

dedupe_array() {
  awk '!seen[$0]++'
}

has_component() {
  local candidate="$1"
  local component

  for component in "${selected_components[@]}"; do
    [[ "$component" == "$candidate" ]] && return 0
  done
  return 1
}

validate_component_set() {
  if has_component light-gateway-rs && has_component light-gateway-java; then
    die "light-gateway-rs and light-gateway-java both publish networknt/light-gateway:$release_tag; release them with different tags"
  fi
}

dry_run=false
local_only=false
push_latest=false
skip_compose_stop=false
write_compose_env_file=true
no_cache=false
profile="lt-rust"
release_tag=""
selected_components=()
PUSH_TAGS=()
LATEST_TAGS=()
ENV_LINES=()

SERVICE_ASSET_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd -- "$SERVICE_ASSET_DIR/.." && pwd)}"
BASE_VERSION="${BASE_VERSION:-2.3.5}"
COMPOSE_ENV_OUT="${COMPOSE_ENV_OUT:-$SERVICE_ASSET_DIR/docker-images.env}"

while (($#)); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      release_tag="$2"
      shift 2
      ;;
    --base-version)
      [[ $# -ge 2 ]] || die "--base-version requires a value"
      BASE_VERSION="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile="$2"
      shift 2
      ;;
    --component)
      [[ $# -ge 2 ]] || die "--component requires a value"
      selected_components+=("$2")
      shift 2
      ;;
    --local)
      local_only=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --push-latest)
      push_latest=true
      shift
      ;;
    --skip-compose-stop)
      skip_compose_stop=true
      shift
      ;;
    --no-compose-env)
      write_compose_env_file=false
      shift
      ;;
    --no-cache)
      no_cache=true
      shift
      ;;
    --list)
      list_profiles_and_components
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -z "$release_tag" ]]; then
  release_tag="${BASE_VERSION}-dev.$(date -u +%Y%m%d.%H%M)"
fi

if [[ ! "$release_tag" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  die "invalid Docker tag: $release_tag"
fi

if ((${#selected_components[@]} == 0)); then
  mapfile -t selected_components < <(profile_components "$profile") || die "unknown profile: $profile"
fi

mapfile -t selected_components < <(printf '%s\n' "${selected_components[@]}" | dedupe_array)
validate_component_set

log "workspace: $WORKSPACE_DIR"
log "release tag: $release_tag"
log "profile: $profile"
log "components: ${selected_components[*]}"

if [[ "$skip_compose_stop" == false ]]; then
  stop_local_compose_stacks
else
  log "skipping local Docker Compose shutdown"
fi

require_command docker

for component in "${selected_components[@]}"; do
  build_component "$component"
done

mapfile -t PUSH_TAGS < <(printf '%s\n' "${PUSH_TAGS[@]}" | dedupe_array)
mapfile -t LATEST_TAGS < <(printf '%s\n' "${LATEST_TAGS[@]}" | dedupe_array)
mapfile -t ENV_LINES < <(printf '%s\n' "${ENV_LINES[@]}" | dedupe_array)

push_tags
write_compose_env

log "release image build completed for tag $release_tag"

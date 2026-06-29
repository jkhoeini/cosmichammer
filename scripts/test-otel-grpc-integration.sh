#!/usr/bin/env zsh
set -euo pipefail

repo_root="${0:A:h}/.."
cd "$repo_root"

if ! command -v docker >/dev/null 2>&1; then
  print -u2 "docker is required to run the local OTLP/gRPC collector integration scaffold."
  exit 127
fi

if ! command -v mise >/dev/null 2>&1; then
  print -u2 "mise is required so Swift runs with the repository toolchain."
  exit 127
fi

if ! command -v rg >/dev/null 2>&1; then
  print -u2 "rg is required to inspect collector readiness and output."
  exit 127
fi

if ! command -v curl >/dev/null 2>&1; then
  print -u2 "curl is required to poll the collector health endpoint."
  exit 127
fi

collector_image="${COSMIC_HAMMER_OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib@sha256:4935caa35e9a4cb387e35732e8fb22b2b5759af8d12e7043357f03837f6e8df5}"
collector_config="$repo_root/Tests/Fixtures/otel-collector-grpc.yaml"
collector_output_dir="$repo_root/build/otel-grpc"
collector_output="$collector_output_dir/otlp-grpc.json"
container_name="cosmichammer-otel-grpc-$$"
grpc_port="${COSMIC_HAMMER_OTEL_GRPC_PORT:-4317}"
health_port="${COSMIC_HAMMER_OTEL_COLLECTOR_HEALTH_PORT:-13133}"

mkdir -p "$collector_output_dir"
rm -f "$collector_output"

preflight_port() {
  local port="$1"
  if command lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    print -u2 "port $port is already in use; set COSMIC_HAMMER_OTEL_GRPC_PORT or COSMIC_HAMMER_OTEL_COLLECTOR_HEALTH_PORT"
    command lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    exit 2
  fi
}

preflight_port "$grpc_port"
preflight_port "$health_port"

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run \
  --rm \
  --detach \
  --name "$container_name" \
  --publish "$grpc_port:4317" \
  --publish "$health_port:13133" \
  --volume "$collector_config:/etc/otelcol/config.yaml:ro" \
  --volume "$collector_output_dir:/tmp/cosmichammer-otel-grpc" \
  "$collector_image" \
  --config /etc/otelcol/config.yaml >/dev/null

collector_ready=false
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:$health_port/" >/dev/null 2>&1; then
    collector_ready=true
    break
  fi
  sleep 1
done

if [[ "$collector_ready" != true ]]; then
  print -u2 "collector did not become ready within 30s"
  docker logs "$container_name" >&2 || true
  exit 1
fi

export COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1
export COSMIC_HAMMER_OTEL_GRPC_ENDPOINT="${COSMIC_HAMMER_OTEL_GRPC_ENDPOINT:-http://127.0.0.1:$grpc_port}"
export COSMIC_HAMMER_OTEL_GRPC_COLLECTOR_OUTPUT="$collector_output"

sdk_path="$(xcrun --show-sdk-path)"
mise exec -- swift test \
  -Xlinker -F -Xlinker "$sdk_path/System/Library/PrivateFrameworks" \
  --filter OpenTelemetryGRPCIntegrationTests

# Give the collector batch processor a chance to export, then stop it cleanly so
# the file exporter flushes the mounted output before we inspect it.
sleep 2
docker stop --time 10 "$container_name" >/dev/null

if [[ ! -s "$collector_output" ]]; then
  print -u2 "collector file exporter did not write $collector_output"
  exit 1
fi

for marker in grpc.integration.trace grpc.integration.log grpc.integration.metric; do
  if ! command rg -q "$marker" "$collector_output"; then
    print -u2 "collector output did not contain expected marker: $marker"
    exit 1
  fi
done
print "Local OTLP/gRPC integration completed; collector output: $collector_output"

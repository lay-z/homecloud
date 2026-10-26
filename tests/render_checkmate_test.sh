#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service checkmate
install_fixture checkmate

rendered="$(render_service checkmate .env .secrets)"
rendered_json="$(render_service_json checkmate .env .secrets)"

assert_render_contains "$rendered" 'name: checkmate' 'project name missing'
assert_render_contains "$rendered" 'container_name: checkmate-checkmate-1' 'checkmate container name missing'
assert_render_contains "$rendered" 'container_name: checkmate-mongodb-1' 'mongodb container name missing'
assert_render_contains "$rendered" 'container_name: checkmate-capture-1' 'capture container name missing'
assert_render_contains "$rendered" "Host(\`status.example.test\`)" 'status host rule missing'
assert_render_contains "$rendered" "Host(\`info.status.example.test\`)" 'info status host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:52345' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/checkmate/mongo-data" 'mongo data bind missing'
assert_render_contains "$rendered" "$TMP/data/checkmate/mongo-configdb" 'mongo configdb bind missing'
assert_render_contains "$rendered" 'source: /var/run/docker.sock' 'docker socket bind missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/checkmate/mongo-data" /data/db 'mongo data bind missing or wrong target' mongodb
assert_mount "$rendered_json" "$TMP/data/checkmate/mongo-configdb" /data/configdb 'mongo configdb bind missing or wrong target' mongodb
assert_mount "$rendered_json" /var/run/docker.sock /var/run/docker.sock 'checkmate docker socket bind missing' checkmate
assert_mount_read_only "$rendered_json" checkmate /var/run/docker.sock /var/run/docker.sock 'docker socket is not read-only'
assert_no_service_mount "$rendered_json" mongodb /var/run/docker.sock /var/run/docker.sock 'mongodb must not mount the docker socket'
assert_no_service_mount "$rendered_json" capture /var/run/docker.sock /var/run/docker.sock 'capture must not mount the docker socket'
assert_mount "$rendered_json" /etc/os-release /etc/os-release 'capture os-release bind missing' capture
assert_mount "$rendered_json" /mnt/old-home /mnt/old-home 'capture old-home bind missing' capture
assert_mount "$rendered_json" /mnt/seagate /mnt/seagate 'capture seagate bind missing' capture
assert_service_env "$rendered_json" checkmate DB_CONNECTION_STRING mongodb://mongodb:27017/uptime_db 'database connection string missing'
assert_service_env "$rendered_json" checkmate CLIENT_HOST https://status.example.test 'client host missing'
assert_service_env "$rendered_json" checkmate CLIENT_CONFIG_CLIENT_HOST https://status.example.test 'client config host missing'
assert_service_env "$rendered_json" checkmate JWT_SECRET test-jwt 'checkmate JWT secret missing'
assert_service_env "$rendered_json" checkmate ENCRYPTION_KEY test-encryption 'checkmate encryption key missing'
assert_service_env "$rendered_json" checkmate CAPTURE_API_SECRET test-capture 'checkmate capture secret missing'
assert_service_env "$rendered_json" capture API_SECRET test-capture 'capture API secret missing'
assert_service_env "$rendered_json" capture GIN_MODE release 'capture mode missing'

printf 'checkmate render tests passed\n'

# Vault server configuration.
#
# This file is mounted read-only into the Vault container at
# /vault/config/config.hcl and consumed via `vault server -config=`.
#
# SECURITY NOTES
#   * tls_disable = 1 is ONLY acceptable for local development. Before using
#     this config against anything reachable from the network, set
#     tls_disable = 0 and provide real certificates.
#   * The Consul storage backend requires a running Consul agent reachable at
#     the address configured below.

# Advertise the node's API address to clients and peers.
api_addr     = "http://vault:8200"
cluster_addr = "https://vault:8201"

# Enable the Web UI at /ui.
ui = true

# Persistent storage backed by Consul. Keys are stored under `vault/` so that
# a single Consul cluster can optionally host multiple Vault instances.
storage "consul" {
  address = "consul:8500"
  path    = "vault/"

  # Consul session TTL for HA leader election.
  session_ttl   = "15s"
  lock_wait_time = "15s"
}

# TCP listener on all interfaces. TLS is intentionally disabled here because
# this Compose stack is meant to run on a single developer laptop. For any
# shared environment replace this block with a tls_cert_file/tls_key_file
# configuration and enable TLS.
listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable   = 1
}

# Prometheus-compatible telemetry. A scraper can hit /v1/sys/metrics?format=prometheus
# (requires a token with the `metrics` policy) to collect Vault metrics.
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}

# Default lease settings. Individual roles/engines can override these.
default_lease_ttl = "768h" # 32 days
max_lease_ttl     = "8760h" # 1 year

# Disable mlock when running in a container where the IPC_LOCK capability may
# not be guaranteed. We prefer cap_add: [IPC_LOCK] in docker-compose, but this
# keeps Vault booting if the capability is missing.
disable_mlock = true

# Plugin directory for custom secret engines. Unused in the default setup but
# present so operators can drop plugins in without editing this file.
plugin_directory = "/vault/plugins"

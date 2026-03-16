#!/bin/bash

service_is_enabled() {
  local service="$1"
  systemctl is-enabled "$service" >/dev/null 2>&1
}

service_is_running() {
  local service="$1"
  systemctl is-active "$service" >/dev/null 2>&1
}

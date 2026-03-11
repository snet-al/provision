#!/bin/bash

profile_multi_deployment() {
  profile_basic
  run_docker
  log_status "skipped" "profile_multi_deployment" "private extension hooks placeholder"
  run_post_setup
}

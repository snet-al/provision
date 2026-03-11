#!/bin/bash

profile_agents() {
  profile_basic
  run_docker
  log_status "skipped" "profile_agents" "agent hooks placeholder"
  run_post_setup
}

#!/bin/bash

run_post_setup() {
  log_info "Running task: post_setup"
  ensure_directory "/home/$DEFAULT_USER/provision" "750" "$DEFAULT_USER:$DEFAULT_USER"
  log_status "ok" "run_post_setup" "post-setup directory permissions ensured"
}

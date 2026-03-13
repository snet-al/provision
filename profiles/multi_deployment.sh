#!/bin/bash

profile_multi_deployment() {
  profile_basic
  run_docker
  run_provision_servers_extension
  run_post_setup
}

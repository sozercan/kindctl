#!/usr/bin/env bats

@test "kindctl real kind/docker integration" {
  "$BATS_TEST_DIRNAME/run-integration.sh"
}

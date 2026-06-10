#!/usr/bin/env bats

@test "kindctl fast suite" {
  TEST_PATTERN="${TEST_PATTERN:-}" "$BATS_TEST_DIRNAME/run-tests.sh"
}

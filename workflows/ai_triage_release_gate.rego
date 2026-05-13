package ai.triage.release

default allow := false

critical_count := input.critical_count
high_count := input.high_count

deny contains msg if {
  input.block_release == true
  msg := "AI triage requested release block"
}

deny contains msg if {
  input.secret_or_credential_risk == true
  msg := "Secret or credential risk detected"
}

deny contains msg if {
  input.internet_exposed_risk == true
  msg := "Internet-exposed risk detected"
}

deny contains msg if {
  critical_count > 0
  msg := sprintf("Critical findings present: %v", [critical_count])
}

deny contains msg if {
  high_count > 5
  msg := sprintf("High finding threshold exceeded: %v", [high_count])
}

allow if {
  count(deny) == 0
}

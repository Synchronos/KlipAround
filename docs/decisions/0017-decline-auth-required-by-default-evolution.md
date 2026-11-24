---
status: accepted
---

# Decline auth-required-by-default protocol evolution

## Context and Problem Statement

Phase 2 introduced optional authenticated mode (`-AuthKey`) to improve message
authenticity, tamper detection, and replay resistance over clipboard transport.
A proposed Phase 3 would have made authentication required by default with a
legacy unauthenticated opt-out path.

KlipAround uses an OS clipboard channel. If an attacker has clipboard access,
the operating environment is treated as unsafe. While `-AuthKey` improves
integrity/authenticity for cooperative peers, it does not convert an unsafe
clipboard environment into a trusted channel.

## Considered Options

* Proceed with Phase 3 and require authentication by default.
* Keep Phase 2 as the long-term model: optional `-AuthKey`, unauthenticated mode
  still supported.

## Decision Outcome

Chosen option: "Keep Phase 2 as the long-term model: optional `-AuthKey`,
unauthenticated mode still supported".

Phase 3 is declined for the current roadmap. Authentication remains opt-in and
documented as optional hardening rather than a complete security boundary.

### Consequences

* Good, because compatibility and operational simplicity are preserved for
  existing deployments that do not manage shared secrets.
* Good, because security messaging stays aligned with the real trust boundary:
  clipboard compromise implies unsafe environment.
* Bad, because default deployments remain susceptible to injection in hostile
  clipboard environments when `-AuthKey` is not used.
* Bad, because users may overestimate protections if optional auth guidance is
  not clearly communicated.

### Confirmation

This decision is reflected in:

* Phase status and rollout updates in
  [protocol-injection-remediation-plan.md](../implementation-plans/protocol-injection-remediation-plan.md)
* Optional auth design and behavior in
  [0016-add-optional-authkey-authentication-mode.md](0016-add-optional-authkey-authentication-mode.md)
* Protocol and operator guidance in
  [protocol-v2.md](../protocol-v2.md) and
  [troubleshooting.md](../troubleshooting.md)

# Architecture Decision Records

A record of *why*, kept next to the code that implements the *what*.

## Why bother

Six months after a decision, the code shows what was chosen. It does not show
what else was considered, what constraint forced the choice, or what would
have to change for the choice to be wrong.

That missing context is why teams re-litigate settled questions, and why a
new engineer "fixes" something that was deliberate. An ADR is cheap insurance
against both.

A good ADR is short and records the **rejected** options honestly. If every
alternative in a record looks obviously bad, the record is marketing rather
than a decision.

## Status values

| Status | Meaning |
|---|---|
| **Proposed** | Under discussion |
| **Accepted** | Decided and implemented |
| **Superseded** | Replaced — links to the record that replaced it |
| **Deprecated** | No longer applies, and nothing replaced it |

Records are **immutable once accepted**. A changed decision is a *new* record
that supersedes the old one; the old one stays, so the history of the
reasoning survives. Editing an accepted ADR destroys exactly the thing it
exists to preserve.

## The records

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-hub-spoke-network-topology.md) | Hub-and-spoke network topology | Accepted |
| [0003](0003-naming-and-tagging.md) | Naming convention and standard tag set | Accepted |
| [0004](0004-cosmos-partition-key.md) | Partition Cosmos containers by `/userId` | Accepted |
| [0005](0005-egress-through-firewall.md) | Force all egress through Azure Firewall | Accepted |
| [0006](0006-aks-private-cluster.md) | Private AKS cluster with no public API endpoint | Accepted |
| [0007](0007-secrets-handling.md) | Eliminate secrets rather than manage them | Accepted |
| [0008](0008-slo-99-95.md) | Set the availability SLO at 99.95% | Accepted |

## Template

```markdown
# NNNN. Title in the imperative

**Status:** Proposed | Accepted | Superseded by [NNNN](...)
**Date:** YYYY-MM-DD

## Context
The forces at play. What constraint makes this a decision rather than an
obvious default?

## Decision
What we are doing. Present tense, active voice: "We partition by userId."

## Consequences
### What this makes easier
### What this makes harder
### What would have to change for this to be wrong

## Alternatives considered
Each with an honest reason for rejection. If they all look obviously bad,
this section is not finished.
```

# 0001. Record architecture decisions

**Status:** Accepted
**Date:** 2026-09-06

## Context

This platform makes a number of decisions that are expensive or impossible to
reverse — a Cosmos partition key, a storage account's hierarchical namespace
flag, an address plan. It also makes decisions that *look* arbitrary and are
not: no CPU limits on containers, an explicit deny rule that duplicates
Azure's implicit one, `maxUnavailable: 0`.

Both kinds get changed by someone who does not know why they were made. The
first kind cannot be changed back.

Commit messages are not sufficient. They record what changed, are rarely read
after the fact, and are attached to a diff rather than to a subject.

## Decision

We record significant architectural decisions as numbered Markdown files in
`docs/adr/`, following Michael Nygard's format.

A decision is significant enough for an ADR if any of these hold:

- it is expensive or impossible to reverse
- it will look wrong to a competent engineer who lacks the context
- a reasonable person could have chosen differently
- it constrains future decisions

Records are immutable once accepted. A reversal is a new record that
supersedes the old one.

## Consequences

### What this makes easier

- Onboarding: a new engineer reads eight files and understands the platform's
  reasoning, not just its shape.
- Review: "this contradicts ADR 0005" is a specific, answerable objection.
- Revisiting: each record states what would have to change for it to be wrong,
  so revisiting is a check rather than an argument.

### What this makes harder

- There is a real cost per decision, and the discipline decays if the bar is
  set too low. Twenty ADRs about naming conventions devalue the eight that
  matter.

### What would have to change for this to be wrong

If the platform stops changing — if it reaches a steady state where no
decisions are being made — the records become archaeology and the overhead
stops paying for itself.

## Alternatives considered

**A wiki.** Drifts from the code immediately, because it lives somewhere the
code review does not. The whole value here is that a change to the code and a
change to its rationale arrive in the same pull request.

**Comments in the code only.** Excellent for local "why is this line like
this" — and used heavily throughout this repository. Poor for decisions
spanning several files, and there is nowhere to record the option that was
rejected.

**Nothing.** The default. It works until the person who made the decision
leaves.

# 0004. Partition Cosmos containers by `/userId`

**Status:** Accepted
**Date:** 2026-09-06

## Context

Cosmos DB shards data into physical partitions of at most 50 GB and 10,000
RU/s each. The partition key determines which logical partition a document
lands in, and therefore whether load spreads or concentrates.

**The choice cannot be changed.** Changing a partition key means creating a
new container and migrating every document.

The product serves 1,000,000 registered users. Each has their own datasets,
their own conversations with the assistant, and reads essentially only their
own data.

Two candidate keys were considered seriously.

## Decision

Partition by **`/userId`** for `users`, `datasets` and `conversations`, and by
`/key` for `idempotency`.

## Consequences

### What this makes easier

- One million logical partitions with near-perfect distribution. No single
  user can create a hot partition that affects others.
- The dominant access pattern — "everything for this user" — is a
  single-partition query, which is the cheapest and fastest operation Cosmos
  offers.
- Point reads by `(userId, id)` cost ~1 RU.

### What this makes harder

- **Any cross-user query is a cross-partition fan-out**, whose RU charge scales
  with the number of physical partitions. Analytics across users must not run
  against Cosmos — it runs against the lakehouse, which is one of the reasons
  the lakehouse exists.
- **Uniqueness is only enforced within a partition.** The unique key on
  `/email` in the `users` container does *not* make email unique across the
  database. A separate mechanism is required if global uniqueness matters, and
  assuming otherwise has produced real production duplicates.
- Multi-tenant admin views ("show me everything for tenant X") are expensive.

### What would have to change for this to be wrong

If the product added a genuinely cross-user feature — a shared workspace, a
collaborative dataset, a leaderboard — the dominant access pattern would change
and this key would stop matching it. That would be a new container with a
different key, not a change to this one.

## Alternatives considered

**`/tenantId`.** The intuitive choice for a B2B SaaS, and the one most teams
reach for. Rejected because it creates a **hot partition** for the largest
tenant: a single logical partition is capped at 10,000 RU/s regardless of what
the container is provisioned for, so the biggest customer — the one you least
want to degrade — hits a ceiling that no amount of money can raise. The failure
presents as 429s at a total load far below the provisioned throughput, which is
deeply confusing the first time you see it. See
[runbook 04](../runbooks/04-cosmos-throttling.md).

**A synthetic key, e.g. `/tenantId_bucket` where bucket is a hash 0-99.**
Spreads a large tenant across 100 partitions and keeps tenant queries to a
bounded fan-out. A legitimate technique. Rejected because it adds application
complexity — every read must compute the bucket — for a benefit `/userId`
provides naturally in this data model. It would be the right answer if tenant-
scoped queries were the dominant pattern.

**`/id` (the document's own id).** Perfect distribution, and every query that
is not a point read becomes a full fan-out. Rejected: it optimises the metric
rather than the workload.

# Documentation

| Section | Contents |
|---|---|
| [Safety and placeholders](00-safety-and-placeholders.md) | The contract this repository keeps: no credentials, no real identifiers, no way to deploy |
| [How to use this repo](00-how-to-use-this-repo.md) | Running the checks locally; what will not work, and why |
| [Architecture](architecture/) | How the platform works and why — 11 documents |
| [Decision records](adr/) | The reasoning, including the rejected alternatives — 8 ADRs |
| [Runbooks](runbooks/) | What to do when something is wrong — 6 runbooks |

## Where to start

Read [`00-safety-and-placeholders.md`](00-safety-and-placeholders.md) first. It
explains why nothing here can be deployed, which is a deliberate property
rather than an unfinished state, and it makes the rest of the repository make
sense.

Then [`architecture/01-system-overview.md`](architecture/01-system-overview.md).

## A note on why there is this much documentation

Roughly a third of this repository is prose. That ratio is deliberate.

Infrastructure code shows *what* was built. It cannot show what else was
considered, what constraint forced a choice, or what would have to change for
the choice to be wrong. That missing context is why teams re-litigate settled
decisions, and why a new engineer "fixes" something that was deliberate.

The comments in the code carry the local reasoning — why *this line* has *this
value*. These documents carry the reasoning that spans files.

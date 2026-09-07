# Jenkins pipelines

The same delivery problem as `.github/workflows/`, solved with a different
tool. Both are here on purpose: understanding *why* they differ is more
valuable than knowing either one.

## The honest comparison

| | GitHub Actions | Jenkins |
|---|---|---|
| **Runs on** | GitHub-hosted or self-hosted runners | Your own controller and agents |
| **Definition** | YAML | Groovy DSL (declarative or scripted) |
| **Reuse** | Composite actions, reusable workflows | Shared libraries (`vars/`) |
| **Setup cost** | Zero | A controller, agents, plugins, and their upgrades |
| **Network reach** | Public runners cannot reach a private VNet | An agent inside the VNet can |
| **Secrets** | OIDC federation, no stored secret | Credentials store, usually long-lived |
| **State** | Stateless by design | Stateful controller — jobs, history, plugin state |
| **Failure mode** | GitHub outage stops all builds | Your controller is a single point of failure you own |

## Why an enterprise Azure platform often still needs Jenkins

This is the part worth understanding, because "just use GitHub Actions" is
usually right and sometimes badly wrong.

The AKS cluster in this platform has **no public API endpoint**. A
GitHub-hosted runner physically cannot reach it. There are three ways out:

1. **`az aks command invoke`** — proxies a command through the Azure control
   plane. Works, but it is a shell-in-a-box: no kubectl streaming, awkward
   file transfer, and every command goes through ARM.
2. **Self-hosted GitHub runners inside the VNet** — works well, and is what
   most greenfield teams choose now. You are running and patching runner VMs,
   which is the thing Actions was supposed to save you from.
3. **Jenkins agents inside the VNet** — which is often what already exists,
   because the organisation adopted Jenkins before it adopted Azure.

Jenkins' real advantage is not features. It is that the agent runs where you
put it, and in a private-network platform that is sometimes decisive.

Its real cost is equally concrete: the controller is infrastructure you
operate, plugins are a genuine supply-chain surface, and Groovy pipelines are
harder to test than YAML.

## What is here

| File | Purpose |
|---|---|
| `Jenkinsfile.validate` | Format, lint, scan, test — the credential-free checks |
| `Jenkinsfile.build` | Build and scan container images |
| `Jenkinsfile.deploy` | The deployment pipeline, **disabled** |
| `vars/` | Shared library — reusable steps |

`Jenkinsfile.deploy` has a hard guard at the top that aborts the build. It
exists to document the shape of a real deployment pipeline, including manual
approval gates and progressive rollout. It cannot run.

## Shared libraries: the thing that makes Jenkins maintainable

A `vars/foo.groovy` file defines a global step `foo()` usable from any
Jenkinsfile in the organisation. Without them, every team copy-pastes the same
40 lines of Terraform setup, and fixing a bug means finding every copy.

Configure once on the controller:

```groovy
library identifier: 'purple-platform@main',
        retriever: modernSCM([$class: 'GitSCMSource', remote: 'https://github.com/Opsworkspace/azure-data-ai-platform.git'])
```

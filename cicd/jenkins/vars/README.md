# Shared library

Reusable pipeline steps. A file `vars/foo.groovy` defining `def call(...)`
becomes a global step `foo()` in every Jenkinsfile that loads the library.

| Step | Does |
|---|---|
| `terraformValidate()` | fmt-check, init `-backend=false`, validate, per directory |
| `securityScan()` | gitleaks, checkov, trivy, placeholder guard |
| `buildContainerImage()` | Reproducible docker build with OCI labels |

## Why a shared library rather than copy-paste

Without one, every team's Jenkinsfile carries its own copy of the Terraform
setup. When the install URL changes, or a flag turns out to be wrong, the fix
has to find every copy — and it never finds all of them. Six months later,
half the organisation is validating Terraform with a version nobody chose.

## Loading it

On the controller, under *Manage Jenkins → System → Global Pipeline
Libraries*, or per-pipeline:

```groovy
@Library('purple-platform@main') _
```

The trailing underscore is required and is a genuine Groovy quirk: the
annotation must attach to *something*, and the underscore is a conventional
throwaway statement. Omitting it fails with an error that does not mention it.

## Testing shared libraries

The hardest part of Jenkins, and the honest weakness of the whole model
compared with YAML pipelines. Options, in increasing order of effort and
value:

1. **Nothing.** Push and see. This is what most teams do, and it means a bug
   in a shared step breaks every pipeline in the organisation at once.
2. **`JenkinsPipelineUnit`** — a Groovy test framework that mocks the pipeline
   DSL, so `call()` can be unit tested. Real work to set up, and it catches
   logic errors before they reach the controller.
3. **A dedicated test pipeline** on a branch, exercising each step against a
   throwaway workspace.

A GitHub Actions composite action has the same problem in a milder form. It is
worth being clear-eyed about: neither system tests its own reusable pieces
well, and that is a real cost of pipeline abstraction.

#!/usr/bin/env groovy

/**
 * Run the security scanners: secrets, IaC misconfiguration, and the
 * repository's own placeholder guard.
 *
 * Usage:
 *   securityScan(terraformDir: 'infra/terraform', failOn: 'HIGH,CRITICAL')
 *
 * @param config.terraformDir  Directory to scan for IaC misconfiguration
 * @param config.failOn        Severities that fail the build
 * @param config.softFail      Report without failing (use only during rollout)
 */
def call(Map config = [:]) {
    String terraformDir = config.get('terraformDir', 'infra/terraform')
    String failOn = config.get('failOn', 'HIGH,CRITICAL')
    boolean softFail = config.get('softFail', false)
    String exitCode = softFail ? '0' : '1'

    // ---- secrets --------------------------------------------------------
    // Full history, not just the diff. A secret committed on Tuesday and
    // removed on Wednesday is still in the history, still clonable, and still
    // compromised. Scanning only the diff finds nothing.
    sh """
        set -euo pipefail
        echo "==> gitleaks (full history)"
        gitleaks detect \
          --config .gitleaks.toml \
          --redact \
          --verbose \
          --exit-code ${exitCode}
    """

    // ---- IaC misconfiguration -------------------------------------------
    // Two scanners rather than one, because their rule sets genuinely differ.
    // Checkov is stronger on cloud-provider-specific policy; Trivy is stronger
    // on general misconfiguration and is much faster. Running both finds more
    // than either alone, and the overlap costs about ninety seconds.
    sh """
        set -euo pipefail
        echo "==> checkov"
        checkov --directory ${terraformDir} \
          --framework terraform \
          --quiet --compact \
          --output cli --output sarif --output-file-path console,checkov.sarif \
          ${softFail ? '--soft-fail' : ''}

        echo "==> trivy config"
        trivy config ${terraformDir} \
          --severity ${failOn} \
          --exit-code ${exitCode} \
          --format sarif --output trivy.sarif
    """

    // ---- the repository's own guard -------------------------------------
    sh 'bash tools/check_placeholders.sh'

    archiveArtifacts artifacts: '*.sarif', allowEmptyArchive: true, fingerprint: true
}

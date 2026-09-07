#!/usr/bin/env groovy

/**
 * Format-check, initialise and validate every Terraform directory.
 *
 * A shared library step rather than 30 lines copied into each Jenkinsfile.
 * The moment two teams have their own copy of this logic, one of them is
 * running an old version of it, and nobody knows which.
 *
 * Usage:
 *   terraformValidate(version: '1.9.8', directory: 'infra/terraform')
 *
 * @param config.version    Terraform version to install
 * @param config.directory  Root directory to search for .tf files
 */
def call(Map config = [:]) {
    String version = config.get('version', '1.9.8')
    String directory = config.get('directory', 'infra/terraform')

    // -backend=false throughout. This is what makes the whole step
    // credential-free: no state is read, no backend is contacted, and the only
    // network call is to the provider registry.
    withEnv([
        "TF_IN_AUTOMATION=true",
        "TF_INPUT=false",
        "TF_PLUGIN_CACHE_DIR=${env.WORKSPACE}/.terraform-plugin-cache",
    ]) {
        sh """
            set -euo pipefail
            mkdir -p "\${TF_PLUGIN_CACHE_DIR}"

            if ! command -v terraform >/dev/null 2>&1; then
                echo "Installing Terraform ${version}"
                curl -fsSL -o /tmp/terraform.zip \
                    "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_amd64.zip"
                unzip -o -q /tmp/terraform.zip -d /tmp
                export PATH="/tmp:\${PATH}"
            fi

            terraform version

            echo "==> Checking canonical formatting"
            terraform fmt -recursive -check -diff ${directory}

            echo "==> Validating every directory"
            failed=0
            while IFS= read -r dir; do
                echo "--> \${dir}"
                terraform -chdir="\${dir}" init -backend=false -input=false -no-color >/dev/null
                terraform -chdir="\${dir}" validate -no-color || failed=1
            done < <(find ${directory} -type f -name '*.tf' -exec dirname {} \; | sort -u)

            exit \${failed}
        """
    }
}

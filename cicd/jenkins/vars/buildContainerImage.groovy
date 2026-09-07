#!/usr/bin/env groovy

/**
 * Build a container image reproducibly.
 *
 * Usage:
 *   buildContainerImage(name: 'purple-api', dockerfile: 'services/api/Dockerfile',
 *                       context: '.', tag: env.IMAGE_TAG)
 *
 * @param config.name        Image name, without registry
 * @param config.dockerfile  Path to the Dockerfile
 * @param config.context     Build context
 * @param config.tag         Immutable tag, normally a git SHA
 */
def call(Map config = [:]) {
    String name = config.name
    String dockerfile = config.dockerfile
    String context = config.get('context', '.')
    String tag = config.tag

    if (!name || !dockerfile || !tag) {
        error('buildContainerImage requires name, dockerfile and tag.')
    }

    sh """
        set -euo pipefail

        # SOURCE_DATE_EPOCH pins timestamps written into the image so that
        # building the same commit twice produces the same digest. Without it,
        # every rebuild differs by file mtimes alone, and "is this the image we
        # tested" becomes unanswerable.
        export SOURCE_DATE_EPOCH=\$(git log -1 --pretty=%ct)

        docker build \
          --file "${dockerfile}" \
          --tag "${name}:${tag}" \
          --tag "${name}:latest" \
          --build-arg BUILDKIT_INLINE_CACHE=1 \
          --label "org.opencontainers.image.revision=\$(git rev-parse HEAD)" \
          --label "org.opencontainers.image.created=\$(date -u -d @\${SOURCE_DATE_EPOCH} +%Y-%m-%dT%H:%M:%SZ)" \
          --label "org.opencontainers.image.source=\$(git config --get remote.origin.url)" \
          "${context}"

        echo "Built ${name}:${tag}"
        docker image inspect "${name}:${tag}" --format 'Size: {{.Size}} bytes'
    """
}

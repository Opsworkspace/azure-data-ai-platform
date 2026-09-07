"""The ingestion worker.

Its job: take a document a user uploaded, split it into chunks, embed each
chunk, and write the results into the AI Search index so the assistant can
retrieve them.

The properties that make this production-shaped rather than a script:

* **Idempotent.** The same message processed twice produces the same result.
  At-least-once delivery is what every queue actually gives you, so exactly-
  once processing has to be built at the consumer, not assumed from the queue.
* **Interruptible.** It runs on spot nodes and can be evicted with 30 seconds'
  notice. It handles SIGTERM by finishing the current chunk and stopping,
  leaving the message unacknowledged so another worker picks it up.
* **Bounded.** Batch sizes and concurrency are capped so one enormous document
  cannot exhaust memory or saturate the embedding model's quota and starve the
  interactive API sharing it.
"""

from __future__ import annotations

import asyncio
import hashlib
import signal
from dataclasses import dataclass
from types import FrameType

from purple_worker.config import get_worker_settings
from purple_worker.telemetry import get_logger

log = get_logger(__name__)

# Flipped by the signal handler; every loop checks it between units of work.
_shutdown_requested = asyncio.Event()


def _handle_sigterm(signum: int, _frame: FrameType | None) -> None:
    """Request a graceful stop.

    Note what this does NOT do: it does not cancel in-flight work. On a spot
    node the eviction notice is 30 seconds, which is enough to finish the
    current chunk and stop cleanly. Cancelling immediately would leave a
    document half-indexed — visible to search but incomplete, which is worse
    than not indexed at all.
    """
    log.info("shutdown_requested", signal=signum)
    _shutdown_requested.set()


@dataclass
class DocumentChunk:
    """One chunk of a document, ready to be embedded and indexed."""

    chunk_id: str
    document_id: str
    document_name: str
    user_id: str
    content: str
    sequence: int


def chunk_document(
    *,
    document_id: str,
    document_name: str,
    user_id: str,
    text: str,
    chunk_size: int = 1000,
    overlap: int = 150,
) -> list[DocumentChunk]:
    """Split text into overlapping chunks.

    **Why overlap.** A fact that straddles a chunk boundary is lost to
    retrieval: neither chunk contains it in full, so neither is a good
    semantic match for a question about it. Overlapping windows mean every
    span of text appears intact in at least one chunk.

    **Why this size.** Chunk size trades precision against context. Small
    chunks retrieve precisely but arrive without surrounding context, so the
    model sees a fragment. Large chunks carry context but dilute the
    embedding — a 4000-token chunk about twelve topics is semantically near to
    none of them. ~1000 characters with 15% overlap is a widely-used starting
    point, and it is a parameter to tune against real questions, not a
    constant to accept.

    **The chunk id is a content hash**, which is what makes reprocessing
    idempotent: re-ingesting an unchanged document produces identical ids and
    overwrites identical documents, rather than duplicating them.
    """
    if overlap >= chunk_size:
        raise ValueError("overlap must be smaller than chunk_size")

    chunks: list[DocumentChunk] = []
    step = chunk_size - overlap
    sequence = 0

    for start in range(0, max(len(text), 1), step):
        content = text[start : start + chunk_size].strip()
        if not content:
            continue

        digest = hashlib.sha256(f"{document_id}|{sequence}|{content}".encode()).hexdigest()[:32]

        chunks.append(
            DocumentChunk(
                chunk_id=digest,
                document_id=document_id,
                document_name=document_name,
                user_id=user_id,
                content=content,
                sequence=sequence,
            )
        )
        sequence += 1

        if start + chunk_size >= len(text):
            break

    return chunks


async def embed_and_index(chunks: list[DocumentChunk]) -> int:
    """Embed chunks and write them to the search index.

    Every indexed document carries `userId`. That field is what the API's
    retrieval filter matches on, so writing it correctly here is the other
    half of the security boundary described in `services/api/app/rag.py`.
    A chunk indexed without a userId is invisible to every filtered query —
    which fails safe, but silently, so it is worth asserting.
    """
    from purple_worker.clients import get_openai_client, get_search_client

    settings = get_worker_settings()
    openai = get_openai_client()
    search = get_search_client()

    indexed = 0

    # Batched. One embedding call per chunk would be both slow and needlessly
    # expensive in request overhead; the API accepts up to 2048 inputs per
    # call, and this stays well under it to bound memory and retry cost.
    for batch_start in range(0, len(chunks), settings.embedding_batch_size):
        if _shutdown_requested.is_set():
            log.info("stopping_between_batches", indexed=indexed)
            break

        batch = chunks[batch_start : batch_start + settings.embedding_batch_size]

        response = await openai.embeddings.create(
            model=settings.openai_embedding_deployment,
            input=[c.content for c in batch],
        )

        documents = []
        for chunk, embedding in zip(batch, response.data, strict=True):
            if not chunk.user_id:
                raise ValueError(f"Chunk {chunk.chunk_id} has no user_id; refusing to index it.")
            documents.append(
                {
                    "chunkId": chunk.chunk_id,
                    "documentId": chunk.document_id,
                    "documentName": chunk.document_name,
                    # The field the API filters on. Non-negotiable.
                    "userId": chunk.user_id,
                    "content": chunk.content,
                    "sequence": chunk.sequence,
                    "contentVector": embedding.embedding,
                }
            )

        # mergeOrUpload, not upload. Content-hashed ids mean a re-ingest
        # overwrites rather than duplicates — this is what makes at-least-once
        # delivery safe.
        await search.merge_or_upload_documents(documents=documents)
        indexed += len(documents)

        log.info("batch_indexed", count=len(documents), total=indexed)

    return indexed


async def run() -> None:
    """The main loop.

    A real implementation pulls from Azure Service Bus or Storage Queues. The
    loop's SHAPE is the part worth reading: check for shutdown, take one unit
    of work, process it, acknowledge it, repeat. Acknowledging only after
    successful processing is what makes an eviction mid-document safe.
    """
    settings = get_worker_settings()
    log.info(
        "worker_starting",
        environment=settings.environment,
        region=settings.region,
        batch_size=settings.embedding_batch_size,
    )

    signal.signal(signal.SIGTERM, _handle_sigterm)
    signal.signal(signal.SIGINT, _handle_sigterm)

    while not _shutdown_requested.is_set():
        # Placeholder for the queue receive. In a funded environment:
        #
        #   async with ServiceBusClient(fqdn, credential) as sb:
        #       receiver = sb.get_queue_receiver("ingestion")
        #       async for message in receiver:
        #           ...process...
        #           await receiver.complete_message(message)
        #
        # The message is completed AFTER processing, never before. Completing
        # first means an eviction loses the work silently.
        try:
            await asyncio.wait_for(_shutdown_requested.wait(), timeout=5.0)
        except TimeoutError:
            continue

    log.info("worker_stopped")


if __name__ == "__main__":
    asyncio.run(run())

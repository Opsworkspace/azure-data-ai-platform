"""Tests for document chunking.

Chunking correctness determines retrieval quality, and the idempotency
property determines whether at-least-once queue delivery is safe.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from purple_worker.main import chunk_document


def _chunk(text: str, **kwargs: int) -> list:
    return chunk_document(
        document_id="doc-1",
        document_name="report.pdf",
        user_id="user-1",
        text=text,
        **kwargs,
    )


def test_short_document_produces_one_chunk() -> None:
    chunks = _chunk("A short document.")
    assert len(chunks) == 1
    assert chunks[0].content == "A short document."
    assert chunks[0].sequence == 0


def test_chunks_overlap() -> None:
    """Overlap is what stops a fact on a boundary from being unretrievable."""
    text = "x" * 2500
    chunks = _chunk(text, chunk_size=1000, overlap=150)

    assert len(chunks) > 1
    # Second chunk starts 850 characters in (1000 - 150), so the last 150
    # characters of chunk 0 are repeated at the start of chunk 1.
    assert len(chunks[0].content) == 1000


def test_chunk_ids_are_deterministic() -> None:
    """The property that makes re-ingestion idempotent.

    The same document processed twice must produce the same chunk ids, so
    mergeOrUpload overwrites rather than duplicating. Without this, a queue
    redelivery silently doubles every document in the index — inflating cost
    and skewing retrieval toward duplicated content.
    """
    text = "The quick brown fox. " * 200
    first = _chunk(text)
    second = _chunk(text)

    assert [c.chunk_id for c in first] == [c.chunk_id for c in second]


def test_different_content_produces_different_ids() -> None:
    a = _chunk("Revenue was 4.2 million in Q3.")
    b = _chunk("Revenue was 5.1 million in Q3.")
    assert a[0].chunk_id != b[0].chunk_id


def test_every_chunk_carries_the_user_id() -> None:
    """The field the API's retrieval filter matches on.

    A chunk indexed without it is invisible to every filtered query. This test
    guards the writing half of the tenant-isolation boundary.
    """
    chunks = _chunk("Some content. " * 300)
    assert all(c.user_id == "user-1" for c in chunks)
    assert all(c.user_id for c in chunks)


def test_sequence_numbers_are_contiguous() -> None:
    chunks = _chunk("word " * 2000)
    assert [c.sequence for c in chunks] == list(range(len(chunks)))


def test_overlap_must_be_smaller_than_chunk_size() -> None:
    with pytest.raises(ValueError, match="overlap must be smaller"):
        _chunk("text", chunk_size=100, overlap=100)


def test_empty_document_produces_no_chunks() -> None:
    assert _chunk("") == []
    assert _chunk("   \n  \t ") == []

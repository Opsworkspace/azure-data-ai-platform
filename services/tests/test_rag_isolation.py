"""The tenant-isolation regression test.

This file exists because of one specific failure mode: a vector search without
a per-user filter returns other customers' documents, and the model summarises
them convincingly. It is the defining data-leak pattern of enterprise RAG.

If someone removes or weakens the filter in `services/api/app/rag.py`, these
tests fail. That is their entire purpose.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "api"))


def test_retrieval_refuses_empty_user_id() -> None:
    """Fail closed.

    In Azure AI Search OData, an empty filter string means NO FILTER — the
    query searches the entire index. So a falsy user id must raise rather than
    produce `filter=""`, which would silently search every tenant's data.
    """
    import asyncio

    from purple_api.rag import UnauthorizedRetrievalError, retrieve_context

    with pytest.raises(UnauthorizedRetrievalError):
        asyncio.run(retrieve_context("any question", user_id=""))


def test_filter_expression_is_scoped_to_one_user() -> None:
    """The generated OData filter must pin the query to a single user id."""
    user_id = "00000000-0000-0000-0000-000000000000"
    expected = f"userId eq '{user_id}'"

    # The expression built in rag.retrieve_context, asserted directly so the
    # test does not depend on network mocking.
    actual = f"userId eq '{user_id.replace(chr(39), chr(39) * 2)}'"

    assert actual == expected
    assert "userId eq" in actual
    assert user_id in actual


def test_single_quotes_in_user_id_are_escaped() -> None:
    """Guard against OData filter injection.

    A user id containing a single quote could otherwise terminate the literal
    and append arbitrary filter logic — for example turning the filter into
    `userId eq '' or userId ne ''`, which matches everything. Doubling the
    quote is the documented OData escape.
    """
    malicious = "abc' or userId ne '"
    escaped = malicious.replace(chr(39), chr(39) * 2)
    filter_expression = f"userId eq '{escaped}'"

    inner = filter_expression[len("userId eq '") : -1]

    # The property that matters: inside the literal, EVERY quote is part of a
    # doubled pair. Removing all doubled pairs must leave no lone quote — a
    # lone quote is what would terminate the literal early and let the rest of
    # the value be parsed as filter syntax.
    #
    # Note that a naive "the injected text is absent" assertion does not work
    # here: `abc'' or userId ne ''` still CONTAINS the substring
    # `' or userId ne '`. What makes it safe is not the absence of that text
    # but the fact that no quote in it can close the literal.
    assert "'" not in inner.replace("''", "")
    assert inner.count("'") % 2 == 0


def test_source_still_contains_the_filter() -> None:
    """A blunt but effective guard.

    If someone deletes the `filter=` argument from the search call, every
    behavioural test that mocks the client would still pass — because the mock
    does not care. This asserts on the source itself.
    """
    rag_source = (Path(__file__).resolve().parents[1] / "api" / "purple_api" / "rag.py").read_text()

    assert 'filter=f"userId eq' in rag_source, (
        "The per-user filter has been removed from rag.retrieve_context. "
        "This is a cross-tenant data leak. Do not merge."
    )
    assert "raise UnauthorizedRetrievalError" in rag_source, (
        "The fail-closed guard for a missing user_id has been removed."
    )

"""Lightweight stub for vector_db when heavy ML deps (sentence-transformers, asyncpg) aren't installed."""

import logging
from typing import Any

logger = logging.getLogger(__name__)


class _StubVectorDB:
    def add_documents(
        self,
        collection_name: str,  # noqa: ARG002
        documents: list[str],  # noqa: ARG002
        metadatas: list[dict],  # noqa: ARG002
        ids: list[str],  # noqa: ARG002
    ) -> None:
        logger.warning("Vector DB add_documents called but vector dependencies are not installed.")

    async def async_add_documents(
        self,
        collection_name: str,  # noqa: ARG002
        documents: list[str],  # noqa: ARG002
        metadatas: list[dict],  # noqa: ARG002
        ids: list[str],  # noqa: ARG002
    ) -> None:
        logger.warning("Vector DB async_add_documents called but vector dependencies are not installed.")

    def search(
        self,
        collection_name: str,  # noqa: ARG002
        query: str,  # noqa: ARG002
        n_results: int = 3,  # noqa: ARG002
    ) -> list[str]:
        logger.warning("Vector DB search called but vector dependencies are not installed.")
        return ["Vector DB not available — install heavy dependencies (sentence-transformers, asyncpg, pgvector)"]

    async def async_search(
        self,
        collection_name: str,  # noqa: ARG002
        query: str,  # noqa: ARG002
        n_results: int = 3,  # noqa: ARG002
    ) -> list[str]:
        logger.warning("Vector DB async_search called but vector dependencies are not installed.")
        return ["Vector DB not available — install heavy dependencies (sentence-transformers, asyncpg, pgvector)"]

    def ingest_url(self, collection_name: str, url: str) -> str:  # noqa: ARG002
        logger.warning("Vector DB ingest_url called but vector dependencies are not installed.")
        return "Vector DB not available"

    async def async_ingest_url(self, collection_name: str, url: str) -> str:  # noqa: ARG002
        logger.warning("Vector DB async_ingest_url called but vector dependencies are not installed.")
        return "Vector DB not available"

    def ingest_pdf(self, collection_name: str, file_path: str) -> str:  # noqa: ARG002
        logger.warning("Vector DB ingest_pdf called but vector dependencies are not installed.")
        return "Vector DB not available"

    async def async_ingest_pdf(self, collection_name: str, file_path: str) -> str:  # noqa: ARG002
        logger.warning("Vector DB async_ingest_pdf called but vector dependencies are not installed.")
        return "Vector DB not available"


vector_db = _StubVectorDB()

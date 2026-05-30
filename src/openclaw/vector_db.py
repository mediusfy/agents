"""Vector similarity search via PostgreSQL + pgvector.

Replaces the previous ChromaDB-backed VectorDBManager with direct SQL
INSERT / SELECT using pgvector's <=> (cosine distance) operator.

Collection names map to pgvector tables, each containing:
  - id        TEXT PRIMARY KEY
  -- metadata JSONB (any scalar-level metadata)
  - embedding vector(384)  — all-MiniLM-L6-v2 produces 384-dim vectors
  - content   TEXT
"""

import asyncio
import logging
import os
from typing import Any

import asyncpg
import numpy as np

from openclaw.settings import settings

logger = logging.getLogger(__name__)

# ── Embedding ──────────────────────────────────────────────────────

_embeddings: Any = None


def _get_embeddings():
    """Lazy-load HuggingFace embeddings (same model as before, 384-dim)."""
    global _embeddings
    if _embeddings is None:
        from sentence_transformers import SentenceTransformer

        _embeddings = SentenceTransformer("all-MiniLM-L6-v2")
    return _embeddings


# ── pgvector helpers ───────────────────────────────────────────────

_connection_pools: dict[str, Any] = {}
_initialized_tables: set[str] = set()

# Test-mode override for _get_pool — set by _set_test_pool() during testing.
# When set, _get_pool returns this pool instead of connecting to PostgreSQL.
_test_pool_override: asyncpg.Pool | None = None


def _set_test_pool(pool: asyncpg.Pool | None):
    """Override _get_pool for testing (bypasses real PostgreSQL)."""
    global _test_pool_override
    _test_pool_override = pool


def _dsn() -> str:
    """Return the PostgreSQL connection string."""
    return settings.database_url or os.environ.get("DATABASE_URL", "postgresql://localhost:5432/openclaw")


async def _get_pool():
    """Return a singleton asyncpg connection pool for the configured DSN.

    In test mode (when _set_test_pool() was called), returns the overridden pool.
    """
    if _test_pool_override is not None:
        return _test_pool_override

    dsn = _dsn()
    if dsn not in _connection_pools:
        _connection_pools[dsn] = await asyncpg.create_pool(dsn, min_size=1, max_size=5)
    return _connection_pools[dsn]


async def _ensure_table(collection_name: str):
    """CREATE TABLE IF NOT EXISTS for the named collection, with pgvector extension."""
    if collection_name in _initialized_tables:
        return
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        await conn.execute(
            f"""
            CREATE TABLE IF NOT EXISTS v_{collection_name} (
                id        TEXT PRIMARY KEY,
                metadata  JSONB NOT NULL DEFAULT '{{}}'::jsonb,
                embedding vector(384) NOT NULL,
                content   TEXT NOT NULL
            )
            """
        )
        # Index for cosine-distance (<=>) search — ivfflat with cosine distance
        await conn.execute(
            f"""
            CREATE INDEX IF NOT EXISTS idx_{collection_name}_embedding
            ON v_{collection_name}
            USING ivfflat (embedding vector_cosine_ops)
            WITH (lists = 100)
            """
        )
    _initialized_tables.add(collection_name)


def _to_embedding(text: str) -> list[float]:
    """Return a 384-dim embedding vector for the given text."""
    model = _get_embeddings()
    vec = model.encode(text, normalize_embeddings=True)
    if isinstance(vec, np.ndarray):
        return vec.tolist()
    return list(vec)


# ── Public interface (same API as old Chroma-based VectorDBManager) ─


class VectorDBManager:
    """Drop-in replacement for the old ChromaDB-backed VectorDBManager.

    All same public methods: add_documents, search, async_add_documents,
    async_search, ingest_url, ingest_pdf, async_ingest_url, async_ingest_pdf.
    """

    async def _add_documents(
        self,
        collection_name: str,
        documents: list[str],
        metadatas: list[dict],
        ids: list[str],
    ):
        await _ensure_table(collection_name)
        pool = await _get_pool()
        async with pool.acquire() as conn:
            for doc_text, meta, doc_id in zip(documents, metadatas, ids, strict=True):
                embedding = _to_embedding(doc_text)
                await conn.execute(
                    f"""
                    INSERT INTO v_{collection_name} (id, metadata, embedding, content)
                    VALUES ($1, $2::jsonb, $3::vector, $4)
                    ON CONFLICT (id) DO UPDATE SET
                        metadata = EXCLUDED.metadata,
                        embedding = EXCLUDED.embedding,
                        content   = EXCLUDED.content
                    """,
                    doc_id,
                    _serialize_meta(meta),
                    embedding,
                    doc_text,
                )

    def add_documents(
        self,
        collection_name: str,
        documents: list[str],
        metadatas: list[dict],
        ids: list[str],
    ):
        """Synchronous convenience wrapper (runs in executor thread)."""
        asyncio.get_event_loop().run_until_complete(self._add_documents(collection_name, documents, metadatas, ids))

    async def async_add_documents(
        self,
        collection_name: str,
        documents: list[str],
        metadatas: list[dict],
        ids: list[str],
    ):
        await self._add_documents(collection_name, documents, metadatas, ids)

    async def _search(
        self,
        collection_name: str,
        query: str,
        n_results: int = 3,
    ) -> list[str]:
        await _ensure_table(collection_name)
        embedding = _to_embedding(query)
        pool = await _get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                f"""
                SELECT content
                FROM v_{collection_name}
                ORDER BY embedding <=> $1::vector
                LIMIT $2
                """,
                embedding,
                n_results,
            )
            return [row["content"] for row in rows]

    def search(self, collection_name: str, query: str, n_results: int = 3) -> list[str]:
        """Synchronous convenience wrapper (runs in executor thread)."""
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # We're inside an async context — create a new task

                future = asyncio.run_coroutine_threadsafe(self._search(collection_name, query, n_results), loop)
                return future.result(timeout=30)
            return loop.run_until_complete(self._search(collection_name, query, n_results))
        except RuntimeError:
            # No running event loop — create one
            return asyncio.run(self._search(collection_name, query, n_results))

    async def async_search(self, collection_name: str, query: str, n_results: int = 3) -> list[str]:
        return await self._search(collection_name, query, n_results)

    def ingest_url(self, collection_name: str, url: str) -> str:
        """Fetch a URL, split into chunks, and index into pgvector."""
        from langchain_community.document_loaders import WebBaseLoader
        from langchain_text_splitters import RecursiveCharacterTextSplitter

        loader = WebBaseLoader(url)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)

        texts = [d.page_content for d in splits]
        metas = [{"source": url} for _ in splits]
        ids = [f"url_{id(s)}" for s in splits]

        loop = asyncio.get_event_loop()
        try:
            loop.run_until_complete(self._add_documents(collection_name, texts, metas, ids))
        except RuntimeError:
            asyncio.run(self._add_documents(collection_name, texts, metas, ids))

        return f"Ingested {len(splits)} chunks from {url}"

    def ingest_pdf(self, collection_name: str, file_path: str) -> str:
        """Load a PDF, split into chunks, and index into pgvector."""
        from langchain_community.document_loaders import PyPDFLoader
        from langchain_text_splitters import RecursiveCharacterTextSplitter

        loader = PyPDFLoader(file_path)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)

        texts = [d.page_content for d in splits]
        metas = [{"source": file_path} for _ in splits]
        ids = [f"pdf_{id(s)}" for s in splits]

        loop = asyncio.get_event_loop()
        try:
            loop.run_until_complete(self._add_documents(collection_name, texts, metas, ids))
        except RuntimeError:
            asyncio.run(self._add_documents(collection_name, texts, metas, ids))

        return f"Ingested {len(splits)} chunks from PDF."

    async def async_ingest_url(self, collection_name: str, url: str) -> str:
        from langchain_community.document_loaders import WebBaseLoader
        from langchain_text_splitters import RecursiveCharacterTextSplitter

        loader = WebBaseLoader(url)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)

        texts = [d.page_content for d in splits]
        metas = [{"source": url} for _ in splits]
        ids = [f"url_{id(s)}" for s in splits]

        await self._add_documents(collection_name, texts, metas, ids)
        return f"Ingested {len(splits)} chunks from {url}"

    async def async_ingest_pdf(self, collection_name: str, file_path: str) -> str:
        from langchain_community.document_loaders import PyPDFLoader
        from langchain_text_splitters import RecursiveCharacterTextSplitter

        loader = PyPDFLoader(file_path)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)

        texts = [d.page_content for d in splits]
        metas = [{"source": file_path} for _ in splits]
        ids = [f"pdf_{id(s)}" for s in splits]

        await self._add_documents(collection_name, texts, metas, ids)
        return f"Ingested {len(splits)} chunks from PDF."


# ── Singleton ──────────────────────────────────────────────────────

vector_db = VectorDBManager()


# ── Helpers ────────────────────────────────────────────────────────


def _serialize_meta(meta: dict[str, Any] | None) -> str:
    """Serialize metadata dict to JSON string for JSONB column.

    Handles nested dicts by flattening them (ChromaDB required scalar metadata;
    pgvector's JSONB happily takes nested structures).
    """
    import json

    if meta is None:
        return "{}"
    # Ensure all values are JSON-serializable
    cleaned: dict[str, Any] = {}
    for k, v in meta.items():
        if isinstance(v, (str, int, float, bool)):
            cleaned[k] = v
        elif v is None:
            cleaned[k] = None
        else:
            # Try to json-dump complex values; fall back to string repr
            try:
                json.dumps(v)
                cleaned[k] = v
            except (TypeError, ValueError):
                cleaned[k] = str(v)
    return json.dumps(cleaned)

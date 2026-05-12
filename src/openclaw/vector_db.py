import os
import asyncio
from typing import List, Dict
from langchain_chroma import Chroma
from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.document_loaders import WebBaseLoader, PyPDFLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter

class VectorDBManager:
    def __init__(self):
        self.persist_directory = os.getenv("VECTOR_DB_DIR", "./.claw-vectordb")
        os.makedirs(self.persist_directory, exist_ok=True)
        self.embeddings = HuggingFaceEmbeddings(model_name="all-MiniLM-L6-v2")
        self._collections = {}

    def _get_collection(self, collection_name: str) -> Chroma:
        if collection_name not in self._collections:
            self._collections[collection_name] = Chroma(
                collection_name=collection_name,
                embedding_function=self.embeddings,
                persist_directory=self.persist_directory
            )
        return self._collections[collection_name]

    def add_documents(self, collection_name: str, documents: List[str], metadatas: List[Dict], ids: List[str]):
        store = self._get_collection(collection_name)
        store.add_texts(texts=documents, metadatas=metadatas, ids=ids)

    def search(self, collection_name: str, query: str, n_results: int = 3) -> List[str]:
        try:
            store = self._get_collection(collection_name)
            # Langchain similarity_search returns Document objects
            docs = store.similarity_search(query, k=n_results)
            return [doc.page_content for doc in docs]
        except Exception as e:
            print(f"[VectorDB] Search failed: {e}")
            return []

    async def async_add_documents(self, collection_name: str, documents: List[str], metadatas: List[Dict], ids: List[str]):
        await asyncio.to_thread(self.add_documents, collection_name, documents, metadatas, ids)

    async def async_search(self, collection_name: str, query: str, n_results: int = 3) -> List[str]:
        return await asyncio.to_thread(self.search, collection_name, query, n_results)

    # LangChain Ingestion 
    
    def ingest_url(self, collection_name: str, url: str):
        """Allows agents to scrape an entire webpage, split it, and embed it efficiently."""
        loader = WebBaseLoader(url)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        
        store = self._get_collection(collection_name)
        store.add_documents(splits)
        return f"Ingested {len(splits)} chunks from {url}"

    def ingest_pdf(self, collection_name: str, file_path: str):
        """Allows agents to read full SEC PDFs or EU Law documents."""
        loader = PyPDFLoader(file_path)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        
        store = self._get_collection(collection_name)
        store.add_documents(splits)
        return f"Ingested {len(splits)} chunks from PDF."

    async def async_ingest_url(self, collection_name: str, url: str) -> str:
        return await asyncio.to_thread(self.ingest_url, collection_name, url)

    async def async_ingest_pdf(self, collection_name: str, file_path: str) -> str:
        return await asyncio.to_thread(self.ingest_pdf, collection_name, file_path)

vector_db = VectorDBManager()

from langchain_community.document_loaders import WebBaseLoader, PyPDFLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_chroma import Chroma
from langchain_community.embeddings import HuggingFaceEmbeddings
import os

class LangChainVectorStore:
    """
    A modernized Vector Database wrapper using LangChain abstractions.
    This replaces manual ChromaDB calls with LangChain's pipeline.
    """
    def __init__(self, persist_directory: str = "./.claw-vectordb"):
        self.persist_directory = persist_directory
        # Using the same sentence-transformers we had in pyproject.toml
        self.embeddings = HuggingFaceEmbeddings(model_name="all-MiniLM-L6-v2")
        self.vectorstore = Chroma(
            collection_name="openclaw_memory",
            embedding_function=self.embeddings,
            persist_directory=self.persist_directory
        )

    def ingest_url(self, url: str):
        """Allows agents to easily scrape an entire webpage, split it, and embed it."""
        loader = WebBaseLoader(url)
        docs = loader.load()
        
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        
        self.vectorstore.add_documents(splits)
        return f"Ingested {len(splits)} chunks from {url}"

    def ingest_pdf(self, file_path: str):
        """Allows the Crypto Oracle to read full 100-page SEC PDFs or EU Law documents."""
        loader = PyPDFLoader(file_path)
        docs = loader.load()
        
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        
        self.vectorstore.add_documents(splits)
        return f"Ingested {len(splits)} chunks from PDF."

    def search_memory(self, query: str, k: int = 5):
        """Semantic search against agent memory."""
        results = self.vectorstore.similarity_search(query, k=k)
        return [doc.page_content for doc in results]

# Singleton instance
lc_memory = LangChainVectorStore()

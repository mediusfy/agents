import os
from typing import Optional

class LiteLLMConfig:
    """
    Configuration manager for switching between local Docker LiteLLM and Cloud Run LiteLLM.
    
    Environment variables:
    - LITELLM_ENV: Set to 'local' (default) or 'cloud' to switch endpoints
    - LITELLM_CLOUD_URL: The URL of your Cloud Run instance
    - LITELLM_VIRTUAL_KEY: Your proxy authorization token
    """
    
    @classmethod
    def get_base_url(cls, endpoint_type: str = "openai") -> str:
        """
        Returns the appropriate base URL for the LiteLLM proxy based on environment.
        endpoint_type can be: 'openai', 'a2a', 'mcp'
        """
        env = os.environ.get("LITELLM_ENV", "local").lower()
        
        if env == "cloud":
            base = os.environ.get("LITELLM_CLOUD_URL", "https://litellm-proxy.run.app")
        else:
            base = "http://0.0.0.0:4000"
            
        if endpoint_type == "openai":
            return f"{base}/v1"
        elif endpoint_type == "a2a":
            return f"{base}/a2a"
        elif endpoint_type == "mcp":
            return f"{base}/mcp"
            
        return base
        
    @classmethod
    def get_api_key(cls) -> str:
        """Returns the virtual key used to authenticate with LiteLLM"""
        return os.environ.get("LITELLM_VIRTUAL_KEY", "sk-MPQ3A_kKYzNrhTpL6tYUVg")
        
    @classmethod
    def configure_openai_client(cls):
        """Helper to automatically configure the standard openai python SDK"""
        import openai
        openai.api_key = cls.get_api_key()
        openai.base_url = cls.get_base_url("openai")
        return openai

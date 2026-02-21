"""
Airflow API client with support for multiple authentication methods.

Priority: JWT Token > Basic Auth > Unauthenticated
"""

import sys
from urllib.parse import urljoin

from airflow_client.client import ApiClient, Configuration

from src.envs import (
    AIRFLOW_API_VERSION,
    AIRFLOW_HOST,
    AIRFLOW_JWT_TOKEN,
    AIRFLOW_PASSWORD,
    AIRFLOW_USERNAME,
    AIRFLOW_VERIFY,
)


def _create_jwt_client() -> ApiClient:
    """Create an API client with JWT token authentication."""
    print("Using JWT token authentication for Airflow", file=sys.stderr)

    configuration = Configuration(
        host=urljoin(AIRFLOW_HOST, f"/api/{AIRFLOW_API_VERSION}"),
    )
    configuration.api_key = {"Authorization": f"Bearer {AIRFLOW_JWT_TOKEN}"}
    configuration.api_key_prefix = {"Authorization": ""}

    return ApiClient(configuration)


def _create_basic_auth_client() -> ApiClient:
    """Create an API client with basic authentication."""
    print("Using basic authentication for Airflow", file=sys.stderr)

    configuration = Configuration(
        host=urljoin(AIRFLOW_HOST, f"/api/{AIRFLOW_API_VERSION}"),
    )
    configuration.username = AIRFLOW_USERNAME
    configuration.password = AIRFLOW_PASSWORD

    if AIRFLOW_VERIFY is False:
        configuration.verify_ssl = False
    elif isinstance(AIRFLOW_VERIFY, str):
        configuration.ssl_ca_cert = AIRFLOW_VERIFY

    return ApiClient(configuration)


def _create_unauthenticated_client() -> ApiClient:
    """Create an API client without authentication (for testing)."""
    print("WARNING: No authentication configured for Airflow", file=sys.stderr)

    configuration = Configuration(
        host=urljoin(AIRFLOW_HOST, f"/api/{AIRFLOW_API_VERSION}"),
    )

    return ApiClient(configuration)


def create_api_client() -> ApiClient:
    """
    Create an Airflow API client with the appropriate authentication method.

    Priority:
    1. JWT Token (if AIRFLOW_JWT_TOKEN is set)
    2. Basic Auth (if AIRFLOW_USERNAME and AIRFLOW_PASSWORD are set)
    3. Unauthenticated (fallback)
    """
    if AIRFLOW_JWT_TOKEN:
        return _create_jwt_client()
    elif AIRFLOW_USERNAME and AIRFLOW_PASSWORD:
        return _create_basic_auth_client()
    else:
        return _create_unauthenticated_client()


# Create the global API client instance
api_client = create_api_client()

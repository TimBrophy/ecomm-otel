import logging
import time
from typing import Any

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

import tracing

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# In-memory product catalog
# ---------------------------------------------------------------------------

PRODUCTS: list[dict[str, Any]] = [
    {
        "id": "prod-001",
        "name": "Wireless Noise-Cancelling Headphones",
        "category": "Electronics",
        "price": 249.99,
        "image_url": "/images/headphones-001.jpg",
    },
    {
        "id": "prod-002",
        "name": "Running Shoes Pro X",
        "category": "Sportswear",
        "price": 129.95,
        "image_url": "/images/shoes-002.jpg",
    },
    {
        "id": "prod-003",
        "name": "Organic Cotton T-Shirt",
        "category": "Clothing",
        "price": 34.99,
        "image_url": "/images/tshirt-003.jpg",
    },
    {
        "id": "prod-004",
        "name": "Stainless Steel Water Bottle 1L",
        "category": "Accessories",
        "price": 24.99,
        "image_url": "/images/bottle-004.jpg",
    },
    {
        "id": "prod-005",
        "name": "Smart Watch Series 5",
        "category": "Electronics",
        "price": 399.00,
        "image_url": "/images/watch-005.jpg",
    },
    {
        "id": "prod-006",
        "name": "Yoga Mat Premium",
        "category": "Sportswear",
        "price": 59.95,
        "image_url": "/images/yogamat-006.jpg",
    },
]

_PRODUCTS_BY_ID: dict[str, dict[str, Any]] = {p["id"]: p for p in PRODUCTS}

# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------


tracing.configure_tracing()

app = FastAPI(
    title="product-service",
    description="E-commerce product catalog — OTel demo",
    version="1.0.0",
)

FastAPIInstrumentor.instrument_app(app)

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/products")
def list_products() -> list[dict[str, Any]]:
    """Return all products. Simulates a 10 ms image-URL lookup per call."""

    time.sleep(0.01)
    logger.info("image_fetch", extra={"product_count": len(PRODUCTS)})

    # Annotate the active span with how many products are returned
    span = trace.get_current_span()
    span.set_attribute("products.count", len(PRODUCTS))

    return PRODUCTS


@app.get("/products/{product_id}")
def get_product(product_id: str) -> dict[str, Any]:
    """Return a single product by ID, or 404."""

    product = _PRODUCTS_BY_ID.get(product_id)
    if product is None:
        logger.warning(
            "product.not_found", extra={"product_id": product_id}
        )
        raise HTTPException(status_code=404, detail=f"Product '{product_id}' not found")

    time.sleep(0.01)
    logger.info(
        "image_fetch",
        extra={"product_count": 1, "product_id": product_id},
    )

    span = trace.get_current_span()
    span.set_attribute("product.id", product_id)
    span.set_attribute("product.category", product["category"])

    return product

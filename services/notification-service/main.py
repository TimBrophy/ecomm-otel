import json
import logging
import os
import time
import threading

from confluent_kafka import Consumer, KafkaError, KafkaException
from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.propagate import extract
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from tracing import configure_tracing

logger = logging.getLogger(__name__)

KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
KAFKA_TOPIC = "order-events"
KAFKA_GROUP_ID = "notification-service"

app = FastAPI(title="notification-service")

_kafka_connected = False
_consumer_thread: threading.Thread | None = None


TRANSIENT_ERRORS = {KafkaError.UNKNOWN_TOPIC_OR_PART, KafkaError._UNKNOWN_PARTITION}


def kafka_consumer_loop() -> None:
    """Run a Kafka consumer loop in a background thread with retry on transient errors."""
    global _kafka_connected

    tracer = trace.get_tracer("notification-service")
    retry_delay = 5

    while True:
        consumer = Consumer(
            {
                "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
                "group.id": KAFKA_GROUP_ID,
                "auto.offset.reset": "earliest",
                "enable.auto.commit": True,
            }
        )
        try:
            consumer.subscribe([KAFKA_TOPIC])
            _kafka_connected = True
            logger.info("Kafka consumer subscribed to topic %s", KAFKA_TOPIC)

            while True:
                msg = consumer.poll(timeout=1.0)
                if msg is None:
                    continue
                if msg.error():
                    if msg.error().code() == KafkaError._PARTITION_EOF:
                        continue
                    if msg.error().code() in TRANSIENT_ERRORS:
                        logger.warning("Kafka transient error (retrying in %ds): %s", retry_delay, msg.error())
                        break
                    logger.error("Kafka fatal error: %s", msg.error())
                    raise KafkaException(msg.error())

                # Extract W3C traceparent from Kafka message headers so this span
                # is linked to the order-service producer span in the same trace.
                # confluent_kafka returns header keys AND values as bytes.
                raw_headers = msg.headers() or []
                headers = {
                    (k.decode() if isinstance(k, bytes) else k):
                    (v.decode() if isinstance(v, bytes) else v)
                    for k, v in raw_headers
                }
                parent_ctx = extract(headers)

                with tracer.start_as_current_span(
                    "notification.send_email", context=parent_ctx
                ) as span:
                    try:
                        payload = json.loads(msg.value().decode("utf-8"))
                    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                        logger.warning("Could not decode Kafka message: %s", exc)
                        continue

                    order_id = payload.get("orderId", payload.get("order_id", "unknown"))
                    span.set_attribute("order.id", order_id)
                    span.set_attribute("messaging.system", "kafka")
                    span.set_attribute("messaging.destination", KAFKA_TOPIC)

                    logger.info("notification.email.sending order_id=%s", order_id)
                    time.sleep(0.02)
                    logger.info("notification.email.sent order_id=%s", order_id)

        except KafkaException:
            logger.exception("Unrecoverable Kafka error — stopping consumer thread")
            return
        finally:
            _kafka_connected = False
            consumer.close()

        logger.info("Reconnecting to Kafka in %ds...", retry_delay)
        time.sleep(retry_delay)


@app.on_event("startup")
async def startup_event() -> None:
    configure_tracing()
    FastAPIInstrumentor.instrument_app(app)

    global _consumer_thread
    _consumer_thread = threading.Thread(
        target=kafka_consumer_loop, name="kafka-consumer", daemon=True
    )
    _consumer_thread.start()
    logger.info("Background Kafka consumer thread started")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "kafka": "connected" if _kafka_connected else "disconnected"}

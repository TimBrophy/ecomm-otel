package com.ecomm.checkout;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.Meter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.Semaphore;

@Service
public class CheckoutService {

    private static final Logger log = LoggerFactory.getLogger(CheckoutService.class);
    private static final Random random = new Random();

    private final RestTemplate restTemplate;
    private final CheckoutRepository checkoutRepository;
    private final String featureFlagServiceUrl;
    private final String orderServiceUrl;

    private volatile boolean fraudDetectionEnabled = false;

    // FraudShield's client SDK caps concurrent connections at 3 — a real limit
    // vendors impose for rate-limiting/cost control. When the fraud check is
    // active, requests queue for a slot instead of failing outright, which is
    // what turns a single slow dependency into cascading checkout latency.
    private static final int FRAUD_CHECK_POOL_SIZE = 3;
    private final Semaphore fraudCheckPool = new Semaphore(FRAUD_CHECK_POOL_SIZE, true);

    // Last-observed end-to-end checkout latency, split by feature flag state.
    // Simple last-value gauges — no cumulative-counter semantics to misread.
    // A state stops being reported once it's gone stale (no traffic in
    // STALE_THRESHOLD_MS), otherwise a state that stopped receiving traffic
    // (e.g. after the flag is reset) would keep reporting its frozen last
    // value forever and silently skew every aggregate that includes it.
    private static final long STALE_THRESHOLD_MS = 10_000;
    private volatile long lastLatencyMsFlagOn = 0;
    private volatile long lastLatencyMsFlagOff = 0;
    private volatile long lastUpdatedFlagOnMillis = 0;
    private volatile long lastUpdatedFlagOffMillis = 0;

    public CheckoutService(RestTemplate restTemplate,
                           CheckoutRepository checkoutRepository,
                           @Value("${feature-flag.service-url}") String featureFlagServiceUrl,
                           @Value("${ORDER_SERVICE_URL:http://order-service:8083}") String orderServiceUrl) {
        this.restTemplate = restTemplate;
        this.checkoutRepository = checkoutRepository;
        this.featureFlagServiceUrl = featureFlagServiceUrl;
        this.orderServiceUrl = orderServiceUrl;

        Meter meter = GlobalOpenTelemetry.getMeter("checkout-service");
        meter.gaugeBuilder("fraud_check.pool.active_connections")
                .ofLongs()
                .setDescription("In-flight calls holding a FraudShield connection pool slot")
                .setUnit("{connection}")
                .buildWithCallback(measurement ->
                        measurement.record(FRAUD_CHECK_POOL_SIZE - fraudCheckPool.availablePermits()));
        meter.gaugeBuilder("fraud_check.pool.queued_requests")
                .ofLongs()
                .setDescription("Requests waiting for a free FraudShield connection pool slot")
                .setUnit("{request}")
                .buildWithCallback(measurement ->
                        measurement.record(fraudCheckPool.getQueueLength()));
        meter.gaugeBuilder("checkout.latency_ms")
                .ofLongs()
                .setDescription("Most recently observed end-to-end checkout processing time, by feature flag state")
                .setUnit("ms")
                .buildWithCallback(measurement -> {
                    long now = System.currentTimeMillis();
                    if (now - lastUpdatedFlagOnMillis < STALE_THRESHOLD_MS) {
                        measurement.record(lastLatencyMsFlagOn,
                                Attributes.of(AttributeKey.booleanKey("feature_flag.realtime_fraud_detection"), true));
                    }
                    if (now - lastUpdatedFlagOffMillis < STALE_THRESHOLD_MS) {
                        measurement.record(lastLatencyMsFlagOff,
                                Attributes.of(AttributeKey.booleanKey("feature_flag.realtime_fraud_detection"), false));
                    }
                });
    }

    // -------------------------------------------------------------------------
    // Feature-flag refresh (every 5 seconds)
    // -------------------------------------------------------------------------

    @Scheduled(fixedDelay = 5000)
    public void refreshFlag() {
        try {
            String url = featureFlagServiceUrl + "/flags/realtime_fraud_detection";
            @SuppressWarnings("unchecked")
            Map<String, Object> response = restTemplate.getForObject(url, Map.class);
            if (response != null && response.containsKey("value")) {
                boolean newValue = Boolean.TRUE.equals(response.get("value"));
                if (newValue != fraudDetectionEnabled) {
                    log.info("Feature flag 'realtime_fraud_detection' changed: {} -> {}", fraudDetectionEnabled, newValue);
                }
                fraudDetectionEnabled = newValue;
            }
        } catch (RestClientException e) {
            log.warn("Could not reach feature-flag service at {}: {}", featureFlagServiceUrl, e.getMessage());
        } catch (Exception e) {
            log.error("Unexpected error refreshing feature flag", e);
        }
    }

    // -------------------------------------------------------------------------
    // Checkout processing
    // -------------------------------------------------------------------------

    /**
     * Processes a checkout request.
     *
     * PII demo: user.email and payment.card_number are set as span attributes
     * intentionally so the EDOT collector's masking pipeline can be demonstrated.
     *
     * Fraud detection demo: when 'realtime_fraud_detection' is enabled, a child
     * span named 'fraud_check' is created simulating a synchronous call to an
     * external fraud API (FraudShield). The check adds 400–900 ms latency and
     * times out on ~8% of requests, cascading latency into order-service and
     * Kafka producer lag downstream.
     */
    public CheckoutResponse processCheckout(CheckoutRequest req) {
        long startNanos = System.nanoTime();
        Span currentSpan = Span.current();

        // PII attributes — intentional for the masking demo
        currentSpan.setAttribute("user.email", req.getEmail());
        currentSpan.setAttribute("payment.card_number", req.getCardNumber());

        // Safe metadata
        currentSpan.setAttribute("checkout.items_count", req.getItems() != null ? req.getItems().size() : 0);
        currentSpan.setAttribute("checkout.total_amount", req.getTotalAmount());
        currentSpan.setAttribute("feature_flag.realtime_fraud_detection", fraudDetectionEnabled);

        // --- Synchronous fraud check when flag is active ----------------------
        if (fraudDetectionEnabled) {
            runFraudCheck(req.getEmail());
        }

        // --- Persist checkout record ------------------------------------------
        String orderId = UUID.randomUUID().toString();

        CheckoutRecord record = new CheckoutRecord();
        record.setOrderId(orderId);
        record.setEmail(req.getEmail());
        record.setStatus("confirmed");
        record.setTotalAmount(req.getTotalAmount());
        record.setCreatedAt(LocalDateTime.now());

        checkoutRepository.save(record);

        log.info("Checkout confirmed: orderId={} email={} total={} fraudDetection={}",
                orderId, req.getEmail(), req.getTotalAmount(), fraudDetectionEnabled);

        // --- Forward to order-service (triggers Kafka publish) ----------------
        try {
            Map<String, Object> orderPayload = Map.of(
                    "orderId", orderId,
                    "customerEmail", req.getEmail(),
                    "items", req.getItems() != null ? req.getItems() : java.util.List.of(),
                    "totalAmount", req.getTotalAmount()
            );
            restTemplate.postForObject(orderServiceUrl + "/orders", orderPayload, Map.class);
            log.info("Order forwarded to order-service orderId={}", orderId);
        } catch (RestClientException e) {
            log.warn("Could not reach order-service orderId={}: {}", orderId, e.getMessage());
        }

        long latencyMs = (System.nanoTime() - startNanos) / 1_000_000;
        if (fraudDetectionEnabled) {
            lastLatencyMsFlagOn = latencyMs;
            lastUpdatedFlagOnMillis = System.currentTimeMillis();
        } else {
            lastLatencyMsFlagOff = latencyMs;
            lastUpdatedFlagOffMillis = System.currentTimeMillis();
        }

        return new CheckoutResponse(orderId, "confirmed", req.getTotalAmount());
    }

    // -------------------------------------------------------------------------
    // Preflight readiness check — called by storefront SSR on checkout page load
    // -------------------------------------------------------------------------

    /**
     * Lightweight FraudShield connectivity probe used by GET /checkout/validate.
     *
     * Runs without acquiring the connection-pool Semaphore so it doesn't compete
     * with live checkouts. When fraud detection is off it returns immediately.
     * When active it adds 200–500 ms to mirror real external-API latency and
     * emits a fraud_check.preflight span so the trace waterfall shows exactly
     * which child span is eating the storefront TTFB budget.
     */
    public Map<String, Object> validateReadiness() {
        boolean fraudActive = fraudDetectionEnabled;
        long validationMs = 0;
        String fraudCheckResult = "skipped";

        if (fraudActive) {
            Tracer tracer = GlobalOpenTelemetry.getTracer("checkout-service");
            Span preflight = tracer.spanBuilder("fraud_check.preflight")
                    .setSpanKind(SpanKind.CLIENT)
                    .startSpan();
            try (Scope scope = preflight.makeCurrent()) {
                preflight.setAttribute("fraud_check.provider", "FraudShield");
                preflight.setAttribute("fraud_check.type", "preflight");
                preflight.setAttribute("peer.service", "fraud-shield-api");
                preflight.setAttribute("server.address", "api.fraudshield.io");

                int delayMs = 200 + random.nextInt(300);
                preflight.setAttribute("fraud_check.duration_ms", delayMs);
                Thread.sleep(delayMs);
                validationMs = delayMs;
                fraudCheckResult = "ready";
                preflight.setAttribute("fraud_check.result", "ready");
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                fraudCheckResult = "interrupted";
            } finally {
                preflight.end();
            }
        }

        return Map.of(
                "ready", true,
                "fraud_detection_active", fraudActive,
                "fraud_check_result", fraudCheckResult,
                "validation_ms", validationMs
        );
    }

    // -------------------------------------------------------------------------
    // Fraud check simulation — creates a visible child span in the trace
    // -------------------------------------------------------------------------

    private void runFraudCheck(String email) {
        Tracer tracer = GlobalOpenTelemetry.getTracer("checkout-service");
        Span fraudSpan = tracer.spanBuilder("fraud_check")
                .setSpanKind(SpanKind.CLIENT)
                .startSpan();

        try (Scope scope = fraudSpan.makeCurrent()) {
            fraudSpan.setAttribute("fraud_check.provider", "FraudShield");
            fraudSpan.setAttribute("peer.service", "fraud-shield-api");
            fraudSpan.setAttribute("server.address", "api.fraudshield.io");

            long waitStart = System.nanoTime();
            fraudCheckPool.acquire();
            long waitMs = (System.nanoTime() - waitStart) / 1_000_000;
            fraudSpan.setAttribute("fraud_check.pool_wait_ms", waitMs);

            try {
                // Simulate variable API latency (400–900 ms)
                int delayMs = 400 + random.nextInt(500);
                fraudSpan.setAttribute("fraud_check.duration_ms", delayMs);

                try {
                    Thread.sleep(delayMs);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                }

                // 8% of requests time out — recorded as a span error
                if (random.nextInt(100) < 8) {
                    String errMsg = "FraudShield API did not respond within 900ms";
                    fraudSpan.setAttribute("fraud_check.result", "timeout");
                    fraudSpan.setStatus(StatusCode.ERROR, errMsg);
                    fraudSpan.recordException(new RuntimeException("FraudCheckTimeoutException: " + errMsg));
                    log.error("fraud_check_timeout=true fraud_check.provider=FraudShield email={} fraud_check_duration_ms={}", email, delayMs);
                    throw new RuntimeException("FraudCheckTimeoutException: " + errMsg);
                }

                fraudSpan.setAttribute("fraud_check.result", "approved");
                log.warn("fraud_check_duration_ms={} fraud_check.provider=FraudShield result=approved email={}", delayMs, email);
            } finally {
                fraudCheckPool.release();
            }
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        } finally {
            fraudSpan.end();
        }
    }
}

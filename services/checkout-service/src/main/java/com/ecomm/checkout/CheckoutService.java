package com.ecomm.checkout;

import io.opentelemetry.api.GlobalOpenTelemetry;
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

@Service
public class CheckoutService {

    private static final Logger log = LoggerFactory.getLogger(CheckoutService.class);
    private static final Random random = new Random();

    private final RestTemplate restTemplate;
    private final CheckoutRepository checkoutRepository;
    private final String featureFlagServiceUrl;
    private final String orderServiceUrl;

    private volatile boolean fraudDetectionEnabled = false;

    public CheckoutService(RestTemplate restTemplate,
                           CheckoutRepository checkoutRepository,
                           @Value("${feature-flag.service-url}") String featureFlagServiceUrl,
                           @Value("${ORDER_SERVICE_URL:http://order-service:8083}") String orderServiceUrl) {
        this.restTemplate = restTemplate;
        this.checkoutRepository = checkoutRepository;
        this.featureFlagServiceUrl = featureFlagServiceUrl;
        this.orderServiceUrl = orderServiceUrl;
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

        return new CheckoutResponse(orderId, "confirmed", req.getTotalAmount());
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
            fraudSpan.end();
        }
    }
}

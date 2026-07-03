package com.ecomm.order;

import io.opentelemetry.api.trace.Span;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class OrderService {

    private static final Logger logger = LoggerFactory.getLogger(OrderService.class);
    private static final String KAFKA_TOPIC = "order-events";
    private static final Random random = new Random();

    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final RestTemplate restTemplate;
    private final String featureFlagServiceUrl;
    private final ConcurrentHashMap<String, OrderResponse> orderStore = new ConcurrentHashMap<>();

    private volatile boolean fraudDetectionEnabled = false;

    public OrderService(KafkaTemplate<String, Object> kafkaTemplate,
                        RestTemplate restTemplate,
                        @Value("${feature-flag.service-url}") String featureFlagServiceUrl) {
        this.kafkaTemplate = kafkaTemplate;
        this.restTemplate = restTemplate;
        this.featureFlagServiceUrl = featureFlagServiceUrl;
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
                    logger.info("Feature flag 'realtime_fraud_detection' changed: {} -> {}", fraudDetectionEnabled, newValue);
                }
                fraudDetectionEnabled = newValue;
            }
        } catch (RestClientException e) {
            logger.warn("Could not reach feature-flag service: {}", e.getMessage());
        } catch (Exception e) {
            logger.error("Unexpected error refreshing feature flag", e);
        }
    }

    // -------------------------------------------------------------------------
    // Order processing
    // -------------------------------------------------------------------------

    public OrderResponse createOrder(OrderRequest req) {
        String orderId = (req.getOrderId() != null && !req.getOrderId().isBlank())
                ? req.getOrderId()
                : UUID.randomUUID().toString();

        String createdAt = Instant.now().toString();

        Span span = Span.current();
        span.setAttribute("order.id", orderId);
        span.setAttribute("order.customer_email", req.getCustomerEmail());
        span.setAttribute("order.total_amount", req.getTotalAmount());

        // When fraud detection is active, checkout is slower and order-service
        // receives a burst of backed-up requests, causing processing delays.
        if (fraudDetectionEnabled) {
            int backpressureMs = 100 + random.nextInt(200);
            span.setAttribute("order.processing_delayed", true);
            span.setAttribute("order.backpressure_ms", backpressureMs);
            logger.warn("fraud_detection_backpressure=true order_processing_delay_ms={} orderId={}", backpressureMs, orderId);
            try {
                Thread.sleep(backpressureMs);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            }
        }

        logger.info("Creating order orderId={} customerEmail={} totalAmount={}",
                orderId, req.getCustomerEmail(), req.getTotalAmount());

        OrderResponse response = new OrderResponse(
                orderId, "CREATED", req.getCustomerEmail(), req.getTotalAmount(), createdAt);

        orderStore.put(orderId, response);
        publishToKafka(orderId, req, response);

        return response;
    }

    public Optional<OrderResponse> getOrder(String orderId) {
        return Optional.ofNullable(orderStore.get(orderId));
    }

    private void publishToKafka(String orderId, OrderRequest req, OrderResponse response) {
        try {
            Map<String, Object> event = Map.of(
                    "orderId", orderId,
                    "customerEmail", req.getCustomerEmail(),
                    "items", req.getItems() != null ? req.getItems() : java.util.List.of(),
                    "totalAmount", req.getTotalAmount(),
                    "status", response.getStatus(),
                    "createdAt", response.getCreatedAt()
            );
            kafkaTemplate.send(KAFKA_TOPIC, orderId, event);
            logger.info("Published order event to Kafka topic={} orderId={}", KAFKA_TOPIC, orderId);
        } catch (Exception e) {
            logger.error("Failed to publish to Kafka orderId={}: {}", orderId, e.getMessage(), e);
        }
    }
}

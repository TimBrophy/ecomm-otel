package com.ecomm.checkout;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class CheckoutController {

    private final CheckoutService checkoutService;

    public CheckoutController(CheckoutService checkoutService) {
        this.checkoutService = checkoutService;
    }

    /**
     * POST /checkout
     *
     * Accepts a CheckoutRequest JSON body, delegates to CheckoutService, and
     * returns a CheckoutResponse. PII attributes (user.email, payment.card_number)
     * are attached to the active OTel span inside the service so the EDOT collector
     * can demonstrate field masking.
     */
    @PostMapping("/checkout")
    public ResponseEntity<CheckoutResponse> checkout(@RequestBody CheckoutRequest request) {
        CheckoutResponse response = checkoutService.processCheckout(request);
        return ResponseEntity.ok(response);
    }

    /**
     * GET /checkout/validate
     *
     * Pre-flight readiness check called by the storefront SSR before rendering the
     * checkout page. When realtime_fraud_detection is active this runs a lightweight
     * FraudShield connectivity probe (200–500 ms), making TTFB — and therefore
     * browser LCP — degrade in lockstep with checkout-service health. The resulting
     * fraud_check.preflight span appears in the same distributed trace as the page
     * load, giving investigators a single waterfall from browser to root cause.
     */
    @GetMapping("/checkout/validate")
    public ResponseEntity<Map<String, Object>> validate() {
        return ResponseEntity.ok(checkoutService.validateReadiness());
    }

    /**
     * GET /health
     *
     * Lightweight liveness probe used by Docker Compose / load balancers.
     * Spring Actuator also exposes /actuator/health with richer detail.
     */
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "ok"));
    }
}

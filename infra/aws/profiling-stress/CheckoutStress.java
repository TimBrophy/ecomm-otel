import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Synthetic checkout workload for Universal Profiling demo.
 *
 * Runs 4 worker threads continuously simulating the checkout → fraud-check →
 * payment → order pipeline. A slow mode is toggled by creating the file
 * /tmp/fraud_check_slow — when present, fraudShieldApiCall() burns CPU and
 * dominates the flame graph, mirroring the realtime_fraud_detection feature
 * flag story in the application demo.
 *
 * Normal mode flame graph: validateCart / fetchProductPrices / processPayment /
 *                          createOrder are roughly equal contributors.
 * Slow mode flame graph:   fraudShieldApiCall → hashTransaction dominates,
 *                          showing FraudShield as the bottleneck.
 */
public class CheckoutStress {

    static final int    THREADS    = 4;
    static final String SLOW_FLAG  = "/tmp/fraud_check_slow";
    static final Random RNG        = new Random();

    public static void main(String[] args) throws InterruptedException {
        System.out.println("CheckoutStress started — " + THREADS + " workers");
        System.out.println("Slow mode: touch " + SLOW_FLAG);
        System.out.println("Normal mode: rm -f " + SLOW_FLAG);

        ExecutorService pool = Executors.newFixedThreadPool(THREADS);
        for (int i = 0; i < THREADS; i++) {
            pool.submit(CheckoutStress::runWorker);
        }
        pool.awaitTermination(Long.MAX_VALUE, java.util.concurrent.TimeUnit.SECONDS);
    }

    static void runWorker() {
        while (!Thread.currentThread().isInterrupted()) {
            try {
                processCheckout();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (Exception ignored) {
            }
        }
    }

    // ── Checkout pipeline ────────────────────────────────────────────────────

    static void processCheckout() throws Exception {
        validateCart();
        fetchProductPrices();
        boolean slow = Files.exists(Paths.get(SLOW_FLAG));
        performFraudCheck(slow);
        processPayment();
        createOrder();
    }

    static void validateCart() {
        long sum = 0;
        for (int i = 0; i < 50_000; i++) sum += i * i;
        if (sum == 0) throw new RuntimeException("unreachable");
    }

    static void fetchProductPrices() throws InterruptedException {
        Thread.sleep(2 + RNG.nextInt(4));
        cacheOperation();
    }

    static void cacheOperation() {
        ArrayList<String> cache = new ArrayList<>(1000);
        for (int i = 0; i < 1000; i++) cache.add("product-" + i);
        cache.sort(String::compareTo);
    }

    // ── Fraud-check path ─────────────────────────────────────────────────────

    static void performFraudCheck(boolean slow) throws InterruptedException {
        if (slow) {
            fraudShieldApiCall();
            connectionPoolAcquire();
        } else {
            Thread.sleep(1 + RNG.nextInt(2));
        }
    }

    static void fraudShieldApiCall() {
        // Burns CPU for 400–900 ms — this is the hot frame in slow mode.
        long deadline = System.currentTimeMillis() + 400 + RNG.nextInt(500);
        while (System.currentTimeMillis() < deadline) {
            hashTransaction();
        }
    }

    static void hashTransaction() {
        // CPU-intensive inner loop — appears prominently in the flame graph.
        String data = "txn-" + System.nanoTime();
        for (int i = 0; i < 2_000; i++) {
            data = Integer.toHexString(data.hashCode())
                 + data.substring(0, Math.min(12, data.length()));
        }
    }

    static void connectionPoolAcquire() throws InterruptedException {
        Thread.sleep(40 + RNG.nextInt(80));
    }

    // ── Payment + order path ─────────────────────────────────────────────────

    static void processPayment() throws InterruptedException {
        Thread.sleep(8 + RNG.nextInt(12));
        tokenizeCard();
    }

    static void tokenizeCard() {
        String card = "4111111111111111";
        for (int i = 0; i < 8_000; i++) {
            card = Integer.toHexString(card.hashCode()) + "xxxx";
        }
    }

    static void createOrder() throws InterruptedException {
        Thread.sleep(4 + RNG.nextInt(8));
        publishKafkaMessage();
    }

    static void publishKafkaMessage() {
        StringBuilder sb = new StringBuilder(16_000);
        for (int i = 0; i < 500; i++) sb.append("order-event-payload-item-").append(i);
        byte[] ignored = sb.toString().getBytes();
        if (ignored.length == 0) throw new RuntimeException("unreachable");
    }
}

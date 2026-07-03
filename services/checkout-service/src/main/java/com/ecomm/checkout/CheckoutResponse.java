package com.ecomm.checkout;

/**
 * Outbound payload returned by POST /checkout.
 */
public class CheckoutResponse {

    private String orderId;
    private String status;
    private double totalAmount;

    public CheckoutResponse() {
    }

    public CheckoutResponse(String orderId, String status, double totalAmount) {
        this.orderId = orderId;
        this.status = status;
        this.totalAmount = totalAmount;
    }

    public String getOrderId() {
        return orderId;
    }

    public void setOrderId(String orderId) {
        this.orderId = orderId;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public double getTotalAmount() {
        return totalAmount;
    }

    public void setTotalAmount(double totalAmount) {
        this.totalAmount = totalAmount;
    }
}

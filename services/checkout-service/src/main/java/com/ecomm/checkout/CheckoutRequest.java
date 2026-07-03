package com.ecomm.checkout;

import java.util.List;

/**
 * Inbound payload for POST /checkout.
 *
 * email and cardNumber are deliberately included so the EDOT collector's
 * attribute masking pipeline can be demonstrated — these would never travel
 * as raw span attributes in a real production service.
 */
public class CheckoutRequest {

    private String email;
    private String cardNumber;
    private List<String> items;
    private double totalAmount;

    public CheckoutRequest() {
    }

    public CheckoutRequest(String email, String cardNumber, List<String> items, double totalAmount) {
        this.email = email;
        this.cardNumber = cardNumber;
        this.items = items;
        this.totalAmount = totalAmount;
    }

    public String getEmail() {
        return email;
    }

    public void setEmail(String email) {
        this.email = email;
    }

    public String getCardNumber() {
        return cardNumber;
    }

    public void setCardNumber(String cardNumber) {
        this.cardNumber = cardNumber;
    }

    public List<String> getItems() {
        return items;
    }

    public void setItems(List<String> items) {
        this.items = items;
    }

    public double getTotalAmount() {
        return totalAmount;
    }

    public void setTotalAmount(double totalAmount) {
        this.totalAmount = totalAmount;
    }
}

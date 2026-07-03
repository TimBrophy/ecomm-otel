package com.ecomm.order;

import java.util.List;

public class OrderRequest {

    private String orderId;
    private String customerEmail;
    private List<String> items;
    private double totalAmount;

    public OrderRequest() {}

    public OrderRequest(String orderId, String customerEmail, List<String> items, double totalAmount) {
        this.orderId = orderId;
        this.customerEmail = customerEmail;
        this.items = items;
        this.totalAmount = totalAmount;
    }

    public String getOrderId() {
        return orderId;
    }

    public void setOrderId(String orderId) {
        this.orderId = orderId;
    }

    public String getCustomerEmail() {
        return customerEmail;
    }

    public void setCustomerEmail(String customerEmail) {
        this.customerEmail = customerEmail;
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

local t = require "skytest"
local delivery = require "skyext.entity.delivery"
local metrics = require "skyext.metrics"

local function metric(name)
    for _, item in ipairs(metrics.collect()) do
        if item.name == name then
            return item
        end
    end
end

t.describe("delivery decision", function()
    t.it("recognizes only the private retryable marker", function()
        local marker = delivery.retryable("mongo down")
        t.expect(delivery.is_retryable(marker)).to.equal(true)
        t.expect(delivery.is_retryable(nil)).to.equal(false)
        t.expect(delivery.is_retryable(false)).to.equal(false)
        t.expect(delivery.is_retryable({ reason = "mongo down" })).to.equal(false)
    end)
end)

t.describe("delivery observability", function()
    t.it("counts retryable conversions and escalates after consecutive failures", function()
        delivery._reset()
        local escalated = false
        local count
        for i = 1, delivery.DEFAULT_ESCALATE_AFTER do
            escalated, count = delivery.note_retryable("role", 7, "msg-1", "mongo down")
            if i < delivery.DEFAULT_ESCALATE_AFTER then
                t.expect(escalated).to.equal(false)
            end
        end
        t.expect(escalated).to.equal(true)
        t.expect(count).to.equal(delivery.DEFAULT_ESCALATE_AFTER)

        local converted = metric("skyext_reliable_msg_retryable_total")
        t.expect(converted).to_not.be_nil()
        local escalated_metric = metric("skyext_reliable_msg_retry_escalated_total")
        t.expect(escalated_metric).to_not.be_nil()
    end)

    t.it("clears the consecutive counter on a successful delivery", function()
        delivery._reset()
        delivery.note_retryable("role", 7, "msg-2", "mongo down")
        delivery.clear("msg-2")
        local escalated = false
        for _ = 1, delivery.DEFAULT_ESCALATE_AFTER - 1 do
            escalated = delivery.note_retryable("role", 7, "msg-2", "mongo down")
        end
        t.expect(escalated).to.equal(false)
    end)

    t.it("tracks the receive-side pending gauge per type", function()
        delivery._reset()
        delivery.observe_pending("role", 7, 3)
        delivery.observe_pending("role", 8, 2)
        local gauge = metric("skyext_reliable_msg_pending")
        t.expect(gauge).to_not.be_nil()
        t.expect(#gauge.samples).to.equal(1)
        t.expect(gauge.samples[1].value).to.equal(5)

        delivery.forget("role", 7)
        gauge = metric("skyext_reliable_msg_pending")
        t.expect(gauge.samples[1].value).to.equal(2)

        delivery.observe_pending("role", 8, 0)
        gauge = metric("skyext_reliable_msg_pending")
        t.expect(gauge.samples[1].value).to.equal(0)
    end)
end)

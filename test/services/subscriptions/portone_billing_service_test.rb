require "test_helper"

# 포트원 빌링키 어댑터 테스트 — W4 F8 v1.0 SIMULATED (PRD 14장 W4 확정).
# 네트워크 스파이: 키 미등록 환경에서 발급·결제 요청은 외부 호출 0(Net::HTTP 접촉 시 예외 주입)으로
# 성공 시뮬레이션 응답을 반환해야 한다 — 외부 API 실호출 금지 원칙(AGENTS·PRD 10장).
class Subscriptions::PortoneBillingServiceTest < ActiveSupport::TestCase
  setup do
    @service = Portone::BillingService.new(api_key: nil, api_secret: nil)
  end

  # 외부 호출 감시 — Net::HTTP.new 접촉 즉시 예외(SIMULATED 경로는 접촉 자체가 없어야 통과)
  def with_network_spy
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*| raise "외부 호출 금지 — SIMULATED 경로만 허용" }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original)
  end

  test "키 미등록 시 configured? false·simulated? true다(v1.0 기본 환경)" do
    assert_not @service.configured?
    assert @service.simulated?

    empty = Portone::BillingService.new(api_key: "  ", api_secret: "")
    assert_not empty.configured?
  end

  test "SIMULATED 빌링키 발급은 외부 호출 없이 성공 응답을 시뮬레이션한다" do
    with_network_spy do
      result = @service.issue_billing_key(customer_uid: "tenant_1")

      assert result.success?
      assert result.simulated?
      assert result.value["billing_key"].start_with?("SIMULATED_BILLING_KEY_")
      assert_equal "tenant_1", result.value["customer_uid"]
    end
  end

  test "SIMULATED 결제 요청은 외부 호출 없이 성공 응답을 시뮬레이션한다" do
    with_network_spy do
      result = @service.request_payment(billing_key: "SIMULATED_BILLING_KEY_x",
                                        amount: 9_900, order_id: "order_1")

      assert result.success?
      assert result.simulated?
      assert result.value["payment_id"].start_with?("SIMULATED_PAYMENT_")
      assert_equal 9_900, result.value["amount"]
      assert_equal "order_1", result.value["order_id"]
      assert result.value["approved_at"].present?
    end
  end

  test "키 등록 + PORTONE_LIVE 미개방 환경은 여전히 SIMULATED다(실호출 이중 게이트)" do
    live_key = Portone::BillingService.new(api_key: "v2_api_key", api_secret: "secret")

    assert live_key.configured?
    assert live_key.simulated? # ENV["PORTONE_LIVE"] != 1 — 개발·테스트 실호출 차단

    with_network_spy do
      result = live_key.request_payment(billing_key: "k", amount: 1_000, order_id: "o")
      assert result.simulated?
    end
  end

  test "실호출 자리는 P1 스파이크 전까지 NotImplementedError로 명확히 차단된다" do
    live_key = Portone::BillingService.new(api_key: "v2_api_key", api_secret: "secret")
    original = ENV["PORTONE_LIVE"]
    ENV["PORTONE_LIVE"] = "1"

    assert_raises(NotImplementedError) do
      live_key.issue_billing_key(customer_uid: "tenant_1")
    end
    assert_raises(NotImplementedError) do
      live_key.request_payment(billing_key: "k", amount: 1_000, order_id: "o")
    end
  ensure
    if original.nil?
      ENV.delete("PORTONE_LIVE")
    else
      ENV["PORTONE_LIVE"] = original
    end
  end
end

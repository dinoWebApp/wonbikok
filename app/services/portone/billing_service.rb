# frozen_string_literal: true

module Portone
  # 포트원 정기결제(빌링키) 어댑터 — W4 F8 v1.0 SIMULATED (PRD 14장 W4 확정 블록).
  # 바로빌 BaseService 패턴 준용: credentials(:portone) 키 미등록 = SIMULATED —
  # 외부 호출 없이 성공 응답 시뮬레이션(P1 이전 "수동 결제·파일럿 무료 운영" 조항 채택).
  #
  # 실호출 게이트: 키 등록 + PORTONE_LIVE=1 환경에서만 시도되며, v1.0에서는 구조 자리만
  # 남긴다(NotImplementedError). 포트원 REST v2의 엔드포인트·파라미터 스펙은 P1 스파이크로
  # 검증 후 구현한다 — 추측 구현 금지(바로빌 스파이크 선행 패턴 준용).
  class BillingService
    Error = Class.new(StandardError)

    # 실호출 응답 구조(P1 대비 정의 — v1.0 미사용)
    Result = Data.define(:success?, :simulated?, :code, :message, :value) do
      def self.ok(value:, code: nil)
        new(success?: true, simulated?: false, code: code, message: nil, value: value)
      end

      def self.failure(code, message)
        new(success?: false, simulated?: false, code: code, message: message, value: nil)
      end
    end

    # SIMULATED 응답 — 외부 호출 없음(Barobill::BaseService::SimulatedResult 준용)
    SimulatedResult = Data.define(:success?, :simulated?, :code, :message, :value) do
      def self.ok(value: nil)
        new(success?: true, simulated?: true, code: "SIMULATED", message: nil, value: value)
      end
    end

    class << self
      def from_credentials
        config = Rails.application.credentials
        new(api_key: config.dig(:portone, :api_key), api_secret: config.dig(:portone, :api_secret))
      end

      # SIMULATED 여부 — 키 미등록 또는 PORTONE_LIVE 게이트 미개방(개발·테스트 실호출 원천 차단)
      def simulated?(api_key)
        api_key.to_s.strip.blank? || ENV["PORTONE_LIVE"] != "1"
      end
    end

    attr_reader :api_key, :api_secret

    def initialize(api_key:, api_secret:)
      @api_key = api_key.to_s
      @api_secret = api_secret.to_s
    end

    # credentials 키 등록 여부(표시·진단용 — 관리자 A3 연동 상태 등). 실호출 가능 여부는
    # configured? && !simulated? 조합(게이트는 메서드별 simulated? 우선).
    def configured?
      api_key.present? && api_secret.present?
    end

    # 게이트는 호출 시점 동적 판정(PORTONE_LIVE는 생성 후에도 개방될 수 있어 캐시하지 않는다)
    def simulated?
      self.class.simulated?(@api_key)
    end

    # 빌링키(카드 정기결제 토큰) 발급 — 카드 등록 경로(F8: 체험 만료 D-7 안내 → 등록).
    def issue_billing_key(customer_uid:, card_credential: nil)
      return SimulatedResult.ok(value: {
        "billing_key" => "SIMULATED_BILLING_KEY_#{SecureRandom.hex(8)}",
        "customer_uid" => customer_uid
      }) if simulated?

      real_call!(:issue_billing_key)
    end

    # 빌링키 결제 요청 — 월 자동결제·재시도 청구(P1).
    def request_payment(billing_key:, amount:, order_id:, customer_uid: nil)
      return SimulatedResult.ok(value: {
        "payment_id" => "SIMULATED_PAYMENT_#{SecureRandom.hex(8)}",
        "order_id" => order_id, "amount" => amount, "approved_at" => Time.current.iso8601
      }) if simulated?

      real_call!(:request_payment)
    end

    private

    # 실호출 구조 자리 — P1에서 REST v2 스펙 검증 후 교체한다(스파이크 선행, 추측 구현 금지).
    def real_call!(method_name)
      raise NotImplementedError,
            "Portone real call (#{method_name}) requires P1 REST v2 spec verification"
    end
  end
end

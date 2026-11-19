# frozen_string_literal: true

module Referral
  # 추천 코드 발급·검증·주간 로테이션 (F10 — REF-001).
  #
  # - 코드: SecureRandom 기반 8자 대문자+숫자(예측 불가 — 유니크 재시도).
  # - 유효기간 7일·직원당 유효 코드 1개 불변: 발급 시 기존 유효 코드는 replaced_at 갱신(이력 보존 —
  #   만료 코드 삭제 금지), 가입 매핑은 tenants.referral_code_snapshot이므로 로테이션 무영향.
  # - verify!는 유효 코드만 직원으로 매핑(만료·불일치 nil — REF-001 가입 거절 근거).
  class CodeService
    CODE_LENGTH = 8
    CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".freeze
    VALIDITY = 7.days

    class << self
      # 직원에게 신규 코드 발급 — 기존 유효 코드는 즉시 교체(replaced_at). 발급된 코드 문자열 반환.
      def issue_for!(sales_rep)
        ActiveRecord::Base.transaction do
          sales_rep.referral_codes.live.update_all(replaced_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          sales_rep.referral_codes.create!(code: generate_unique_code, expires_at: VALIDITY.from_now).code
        end
      end

      # 유효 코드 검증(REF-001) — 유효 시 해당 직원, 만료·불일치 nil. 코드는 대소문자·공백 정규화.
      def verify!(code)
        normalized = normalize(code)
        return nil if normalized.blank?

        ReferralCode.live.find_by(code: normalized)&.sales_rep
      end

      # 주간 로테이션(월요일 09:00 — ReferralCodeRotationJob) — 활성 직원 전원 재발급.
      # 정지 직원은 코드 발급 대상 제외(정지 시 코드 무효는 suspend!가 이미 수행 — REF-007).
      # 반환: 재발급 건수.
      def rotate_all!
        SalesRep.active.filter_map { |sales_rep| issue_for!(sales_rep) }.length
      end

      private

      def generate_unique_code
        loop do
          candidate = generate_code
          return candidate unless ReferralCode.exists?(code: candidate) # 유니크 재시도
        end
      end

      def generate_code
        Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
      end

      def normalize(code)
        code.to_s.strip.upcase.presence
      end
    end
  end
end

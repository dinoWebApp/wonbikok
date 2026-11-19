# frozen_string_literal: true

module Signup
  # 가입 휴대폰 인증 (F10 — REF-006: 가입은 인증 완료 시에만·시도 5회 제한·평문 저장 금지).
  #
  # - send_code!: 정규화 → 기존 미소비 레코드 무효화(expires_at 경과 처리 — 재발송 이전 코드 차단) →
  #   6자리 코드 bcrypt 해시 저장(code_digest — 평문 저장 금지) → 솔라피 알림톡 발송
  #   (SIMULATED·기존 Solapi::Client 재사용·인증 템플릿 유형 — 카카오 심사는 운영 과제).
  #   레이트 리밋: 동일 번호 1분 1회(발송 이력 조회 기반 — 서버측 강제).
  #
  # [설계 결정] 발송은 본 서비스에서 동기 수행한다(외부 호출은 전용 Service 객체 경유만 강제).
  # MessageSendJob처럼 잡으로 넘기면 일회성 코드 원문이 Solid Queue 잡 인자로 DB에 저장되어
  # REF-006 평문 저장 금지 원칙을 위반한다 — 코드는 bcrypt로 복원 불가하므로 잡이 재구성할 수도 없다.
  # (03_implementation.md 설계 결정 절에 명시)
  #
  # - verify!: 만료·시도 5회 초과·불일치 검증. 성공 시 verified_at 기록, 실패 시 attempts 증가.
  # - consume!: 가입 create 성공 시 소비 표시(consumed_at) — 검증 정보 재사용 방지(원자 갱신).
  #
  # 인증 상태의 원천은 DB(signup_verifications) — 세션 의존 없이 create가 서버 재검증한다.
  class PhoneVerificationService
    RESEND_INTERVAL = 1.minute
    PHONE_FORMAT = /\A01[016789]\d{7,8}\z/

    Result = Data.define(:reason, :verification) do
      def ok?
        reason == :ok
      end
    end

    class << self
      # 인증번호 발송. reason: :ok / :invalid_phone / :rate_limited
      # (W-1: 솔라피 호출은 create! 커밋 후 — 트랜잭션 내 외부 호출·쓰기 잠금 홀드 방지.
      #  발송 실패는 deliver! 내부 rescue로 흡수되어 코드 발급에는 영향 없음 — 기존 규약 동일)
      def send_code!(phone_number)
        normalized = normalize(phone_number)
        return Result.new(:invalid_phone, nil) if normalized !~ PHONE_FORMAT
        return Result.new(:rate_limited, nil) if recently_sent?(normalized)

        code = generate_code
        verification = nil
        ActiveRecord::Base.transaction do
          invalidate_unconsumed!(normalized)
          verification = SignupVerification.create!(
            phone_number: normalized,
            code_digest: BCrypt::Password.create(code),
            expires_at: SignupVerification::TTL.from_now
          )
        end
        deliver!(verification, code)
        Result.new(:ok, verification)
      end

      # 코드 검증. reason: :ok / :not_found / :expired / :attempts_exceeded / :mismatch
      def verify!(phone_number, code)
        normalized = normalize(phone_number)
        verification = SignupVerification.unconsumed.where(phone_number: normalized).order(id: :desc).first
        return Result.new(:not_found, nil) if verification.nil?
        return Result.new(:attempts_exceeded, verification) if verification.attempts_exhausted?
        return Result.new(:expired, verification) if verification.expired?

        if BCrypt::Password.new(verification.code_digest) == normalize_code(code)
          verification.update!(verified_at: Time.current)
          Result.new(:ok, verification)
        else
          verification.increment!(:attempts) # 실패 시도 누적 — 5회 도달 시 차단(REF-006)
          Result.new(:mismatch, verification)
        end
      end

      # 검증 완료(verified·미소비·미만료) 레코드 소비 — 가입 create 서버 검증 단일 진입점.
      # 원자 갱신(update_all ... WHERE consumed_at IS NULL)으로 동시 가입 레이스에서도 1회만 소비.
      # 소비 성공 시 해당 레코드 반환, 조건 불일치(미검증·소비됨·만료) nil.
      def consume!(phone_number, at: Time.current)
        normalized = normalize(phone_number)
        target_ids = SignupVerification.unconsumed.verified
                                       .where(phone_number: normalized)
                                       .where(expires_at: at..)
                                       .order(id: :desc).limit(1).ids
        return nil if target_ids.empty?

        updated = SignupVerification.where(id: target_ids, consumed_at: nil)
                                    .update_all(consumed_at: at) # rubocop:disable Rails/SkipsModelValidations
        updated == 1 ? SignupVerification.find(target_ids.first) : nil
      end

      private

      # 솔라피 발송 — 키 미설정 시 SIMULATED 로그(개발·테스트 한정 코드 표시 — 운영 노출 금지).
      # 발송 실패는 코드 발급 자체를 막지 않는다(재발송 1분 제한으로 회복 — 무한 재시도 금지 MSG-003 정신).
      def deliver!(verification, code)
        if simulated?
          Rails.logger.info(
            "[Signup::PhoneVerificationService] SIMULATED 인증번호 발송 — phone=**masked** " \
            "verification_id=#{verification.id}"
          )
          Rails.logger.info("[Signup::PhoneVerificationService] 코드(개발 전용 표시)=#{code}") if Rails.env.local?
          return
        end

        config = Rails.application.config_for(:solapi)
        message = {
          to: verification.phone_number, # 복호화(deterministic 암호화 컬럼 — TEN-003)
          text: I18n.t("signup_verification.sms_text", code: code),
          kakao_options: {
            pf_id: config.dig(:kakao, :pf_id),
            template_id: config.dig(:kakao, :templates, :signup_verification),
            variables: { "인증번호" => code }
          }
        }
        result = Solapi::Client.from_credentials.send_messages([ message ])
        Rails.logger.info("[Signup::PhoneVerificationService] sent id=#{verification.id} " \
                          "success=#{result.success?} fallback=#{result.fallback?} " \
                          "error=#{result.error_code}")
      rescue Solapi::Client::ConfigError, Solapi::Client::Error => e
        Rails.logger.error("[Signup::PhoneVerificationService] 발송 실패 id=#{verification.id} " \
                           "error=#{e.class}: #{e.message}")
      end

      def simulated?
        config = Rails.application.config_for(:solapi)
        config[:api_key].blank? || config[:api_secret].blank?
      rescue StandardError
        true
      end

      # 동일 번호 1분 1회(REF-006 남용 방지) — 재발송 간격 이내 발송 이력 존재 여부.
      def recently_sent?(normalized, at: Time.current)
        SignupVerification.where(phone_number: normalized, created_at: (at - RESEND_INTERVAL)..).exists?
      end

      # 재발송 시 기존 미소비 레코드 무효화 — 만료 시점을 현재로 당겨 검증·소비 불가로 처리.
      # (레코드 자체는 이력 보존 — 검증 시도·소비 이력 추적용)
      def invalidate_unconsumed!(normalized)
        SignupVerification.unconsumed.where(phone_number: normalized)
                          .update_all(expires_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end

      def generate_code
        format("%0#{SignupVerification::CODE_LENGTH}d",
               SecureRandom.random_number(10**SignupVerification::CODE_LENGTH))
      end

      def normalize(phone_number)
        phone_number.to_s.gsub(/[^0-9]/, "")
      end

      def normalize_code(code)
        code.to_s.gsub(/[^0-9]/, "")
      end
    end
  end
end

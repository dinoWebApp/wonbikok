# 관리자 2단계 인증 OTP (PRD 12장 A0 — 사전 공유 시크릿 기반 6자리 TOTP).
# RFC 6238 간단 구현: HMAC-SHA1 · 30초 스텝 · 6자리 · Base32 시크릿 — 외부 젬 불사(1인 운영 최소 의존).
#
# 시크릿 결정 순서:
#   1) admin_users.otp_secret (사전 공유 시크릿 — 시드/콘솔에서 설정)
#   2) 미설정 시 credentials.dig(:admin, :otp_seed)에서 계정별 파생(HMAC-SHA1(seed, email) → Base32)
#      - credentials에 otp_seed 미설정인 개발·테스트 환경: 고정 폴백 시드 사용 + 경고 로그 1회(W-2 — 로컬 한정)
#      - 운영 환경에서 otp_secret·otp_seed 모두 미설정: 인증 거부(SecretUnavailableError — 개발 폴백 시크릿의
#        운영 유출 방지. verify?는 이 예외를 로그+실패로 전환해 로그인을 막는다)
#      - credentials 수정은 본 서비스에서 금지(읽기만) — 운영 시크릿 유출 방지(ADM-002)
#
# 검증은 현재 스텝 ±1(최대 90초 시계 오차 허용)까지 허용하는 표준 TOTP 관행을 따른다.
# 코드 비교는 secure_compare로 수행(타이밍 공격 방지).
module Admin
  class OtpService
    STEP_SECONDS = 30
    CODE_DIGITS = 6
    ALLOWED_STEP_DRIFT = 1

    BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze
    DEV_FALLBACK_SEED = "wonbikok-dev-otp-seed-do-not-use-in-production".freeze

    # 운영에서 otp_secret·otp_seed가 모두 없어 인증 시크릿을 만들 수 없을 때(W-2)
    SecretUnavailableError = Class.new(StandardError)

    class << self
      # 로그인 2단계 검증. 성공/실패 boolean. 실패 카운트·잠금은 호출측(Admin::SessionsController) 담당.
      def verify?(admin_user, code, at: Time.current)
        return false if code.blank?

        expected_steps(at).any? do |counter|
          ActiveSupport::SecurityUtils.secure_compare(generate_code(secret_for(admin_user), counter),
                                                       code.to_s.gsub(/\s/, ""))
        end
      rescue SecretUnavailableError => e
        Rails.logger.error("[Admin::OtpService] 운영 OTP 인증 거부 — #{e.message}")
        false
      end

      # 콘솔/개발 확인용 현재 코드(bin/rails runner — 운영 화면·로그 노출 금지, ADM-002)
      def current_code(admin_user, at: Time.current)
        generate_code(secret_for(admin_user), step_counter(at))
      end

      # 유효 시크릿 — otp_secret 컬럼 우선, 없으면 시드 파생(계정별 고정값).
      def secret_for(admin_user)
        admin_user.otp_secret.presence || derived_secret(admin_user.email)
      end

      # otp_seed에서 계정별 시크릿 파생(Base32 32자 — TOTP 표준 엔트로피)
      def derived_secret(email)
        seed = otp_seed
        digest = OpenSSL::HMAC.digest("SHA1", seed, "admin-otp:#{email.to_s.strip.downcase}")
        encode_base32(digest).first(32)
      end

      private

      def expected_steps(at)
        counter = step_counter(at)
        (counter - ALLOWED_STEP_DRIFT)..(counter + ALLOWED_STEP_DRIFT)
      end

      def step_counter(at)
        at.to_i / STEP_SECONDS
      end

      def generate_code(secret_base32, counter)
        key = decode_base32(secret_base32).pack("C*") # 바이트 배열 → 바이너리 문자열(HMAC 키)
        return "" if key.empty?

        hmac = OpenSSL::HMAC.digest("SHA1", key, [ counter ].pack("Q>"))
        offset = hmac.bytes.last & 0x0f
        code = (hmac.bytes[offset, 4].pack("C4").unpack1("N") & 0x7fff_ffff) % (10**CODE_DIGITS)
        format("%0#{CODE_DIGITS}d", code)
      end

      def otp_seed
        seed = Rails.application.credentials.dig(:admin, :otp_seed)
        return seed if seed.present?

        # 개발 폴백 시크릿은 development/test 한정(W-2) — 운영에서는 인증 거부
        raise SecretUnavailableError,
              "credentials :admin/:otp_seed 미설정 — 운영 환경에서는 관리자 OTP 인증을 거부합니다" unless Rails.env.local?

        unless @seed_warned
          Rails.logger.warn(
            "[Admin::OtpService] credentials :admin/:otp_seed 미설정 — 개발 폴백 시크릿 사용 중 " \
            "(운영 배포 전 필수 설정: A0 2단계 인증)"
          )
          @seed_warned = true
        end
        DEV_FALLBACK_SEED
      end

      def decode_base32(value)
        input = value.to_s.upcase.tr("=", "").gsub(/[^#{BASE32_ALPHABET}]/, "")
        bits = input.chars.map { |char| BASE32_ALPHABET.index(char).to_s(2).rjust(5, "0") }.join
        # 완성된 8비트 바이트만 취하고 잉여 비트(<8)는 버림(RFC 4648 패딩 없이 디코드)
        bits.scan(/.{8}/).map { |byte| byte.to_i(2) }
      end

      def encode_base32(data)
        bits = data.bytes.map { |byte| byte.to_s(2).rjust(8, "0") }.join
        bits += "0" while bits.length % 5 != 0
        bits.scan(/.{5}/).map { |chunk| BASE32_ALPHABET[chunk.to_i(2)] }.join
      end
    end
  end
end

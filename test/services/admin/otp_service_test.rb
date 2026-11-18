require "test_helper"

module Admin
  class OtpServiceTest < ActiveSupport::TestCase
    # RFC 6238 부록 B SHA1 벡터용 시크릿(ASCII "12345678901234567890"의 Base32 인코딩)
    RFC_VECTOR_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ".freeze

    def admin_with(secret: nil, email: "otp@example.com")
      AdminUser.create!(email: email, password: "admin-pass-123", otp_secret: secret)
    end

    test "RFC 6238 벡터 준수 — Time.at(59)에서 6자리 코드는 287082" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)

      # 부록 B: SHA1·8자리 94287082 → 6자리 절단 287082
      assert_equal "287082", Admin::OtpService.current_code(admin, at: Time.at(59))
    end

    test "유효 코드를 검증한다" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)
      code = Admin::OtpService.current_code(admin, at: Time.current)

      assert Admin::OtpService.verify?(admin, code)
    end

    test "직전 스텝 코드(30초 이내 시계 오차)도 허용한다" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)
      code = Admin::OtpService.current_code(admin, at: 29.seconds.ago)

      assert Admin::OtpService.verify?(admin, code)
    end

    test "2스텝 이전 코드는 거부한다(허용 오차 ±1스텝)" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)
      code = Admin::OtpService.current_code(admin, at: 61.seconds.ago)

      assert_not Admin::OtpService.verify?(admin, code)
    end

    test "잘못된 코드는 거부하고 공백 포함 입력은 정규화한다" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)
      code = Admin::OtpService.current_code(admin, at: Time.current)

      assert_not Admin::OtpService.verify?(admin, "000000")
      assert_not Admin::OtpService.verify?(admin, "12345") # 자릿수 다름
      # 공백 정규화 — 같은 숫자라면 통과
      assert Admin::OtpService.verify?(admin, code.chars.join(" "))
    end

    test "빈 코드는 거부한다" do
      admin = admin_with(secret: RFC_VECTOR_SECRET)

      assert_not Admin::OtpService.verify?(admin, "")
      assert_not Admin::OtpService.verify?(admin, nil)
    end

    test "otp_secret 미설정 시 credentials otp_seed에서 계정별 파생한다(결정적)" do
      admin = admin_with(email: "derived@example.com")
      code = Admin::OtpService.current_code(admin, at: Time.current)

      assert_not_empty code
      assert_match(/\A\d{6}\z/, code)
      # 같은 이메일 → 같은 파생 시크릿(결정성), 다른 이메일 → 다른 시크릿
      assert_equal Admin::OtpService.derived_secret("derived@example.com"),
                   Admin::OtpService.derived_secret("derived@example.com")
      assert_not_equal Admin::OtpService.derived_secret("derived@example.com"),
                       Admin::OtpService.derived_secret("other@example.com")
    end

    test "otp_secret이 설정되면 컬럼 값을 우선 사용한다" do
      admin = admin_with(email: "override@example.com")
      derived_code = Admin::OtpService.current_code(admin, at: Time.current)

      admin.update!(otp_secret: RFC_VECTOR_SECRET)
      explicit_code = Admin::OtpService.current_code(admin, at: Time.current)

      assert Admin::OtpService.verify?(admin, explicit_code)
      # 파생 시크릿과 명시 시크릿은 다르므로 기존 코드는 더 이상 유효하지 않다
      assert_not Admin::OtpService.verify?(admin, derived_code)
    end

    test "derived_secret은 Base32 32자를 반환한다" do
      secret = Admin::OtpService.derived_secret("base32@example.com")

      assert_match(/\A[A-Z2-7]{32}\z/, secret)
    end
  end
end

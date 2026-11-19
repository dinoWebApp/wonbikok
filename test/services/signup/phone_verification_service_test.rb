require "test_helper"

# 가입 휴대폰 인증 서비스 테스트 (F10 — REF-006: 발송·검증·시도 5회·만료·소비·레이트 리밋).
# 솔라피는 SIMULATED(키 미설정) — 외부 실호출 금지.
class Signup::PhoneVerificationServiceTest < ActiveSupport::TestCase
  PHONE = "01012345678"

  test "REF-006 send_code!은 6자리 코드를 bcrypt 해시로 저장하고(평문 금지) 발송 기록을 남긴다" do
    result = Signup::PhoneVerificationService.send_code!(PHONE)

    assert result.ok?
    verification = result.verification.reload
    assert_not_nil verification
    assert_in_delta 5.minutes.from_now, verification.expires_at, 5
    digest = verification.code_digest
    assert digest.start_with?("$2a$") # bcrypt
    assert_not_includes digest, "123456"
    # raw 저장 평문 없음
    raw = SignupVerification.connection.select_value(
      "SELECT code_digest FROM signup_verifications WHERE id = #{verification.id}"
    )
    assert raw.to_s.start_with?("$2a$")
  end

  test "REF-006 번호는 정규화되고 잘못된 형식은 거절된다" do
    result = Signup::PhoneVerificationService.send_code!("010-1234-5678")
    assert result.ok?
    assert_equal "01012345678", result.verification.reload.phone_number

    assert_not Signup::PhoneVerificationService.send_code!("010123").ok?
    assert_not Signup::PhoneVerificationService.send_code!("010999999999").ok?
    assert_not Signup::PhoneVerificationService.send_code!("").ok?
  end

  test "REF-006 동일 번호 1분 1회 레이트 리밋이 적용된다" do
    assert Signup::PhoneVerificationService.send_code!(PHONE).ok?
    limited = Signup::PhoneVerificationService.send_code!(PHONE)

    assert_equal :rate_limited, limited.reason
    assert_equal 1, SignupVerification.where(phone_number: PHONE).count
  end

  test "REF-006 다른 번호는 즉시 발송할 수 있다(레이트 리밋은 번호별)" do
    assert Signup::PhoneVerificationService.send_code!(PHONE).ok?
    assert Signup::PhoneVerificationService.send_code!("01099998888").ok?
  end

  test "REF-006 재발송이 가능해지면 기존 미소비 코드는 무효화되고 새 코드로만 검증된다" do
    first = Signup::PhoneVerificationService.send_code!(PHONE)
    # 레이트 리밋 우회 — 첫 레코드 생성시각을 2분 전으로 백데이팅(테스트 전용 조작)
    first.verification.update_columns(created_at: 2.minutes.ago) # rubocop:disable Rails/SkipsModelValidations

    with_fixed_verification_code("777777") do
      second = Signup::PhoneVerificationService.send_code!(PHONE)
      assert second.ok?

      assert first.verification.reload.expired? # 기존 코드 무효화(만료 시점 현재로 당겨짐)
      # 검증 대상은 항상 최신 레코드 — 새 코드로 검증 성공
      assert Signup::PhoneVerificationService.verify!(PHONE, "777777").ok?
    end
  end

  test "REF-006 verify!는 올바른 코드에서 verified_at을 기록한다" do
    created = nil
    with_fixed_verification_code("654321") do
      created = Signup::PhoneVerificationService.send_code!(PHONE).verification
      result = Signup::PhoneVerificationService.verify!(PHONE, "654321")

      assert result.ok?
    end
    assert created.reload.verified?
  end

  test "REF-006 verify!는 만료 코드를 거절한다" do
    with_fixed_verification_code("111111") do
      verification = Signup::PhoneVerificationService.send_code!(PHONE).verification
      verification.update!(expires_at: 1.minute.ago)

      result = Signup::PhoneVerificationService.verify!(PHONE, "111111")
      assert_equal :expired, result.reason
      assert_not verification.reload.verified?
    end
  end

  test "REF-006 verify!는 5회 실패 후 차단된다(시도 제한)" do
    with_fixed_verification_code("222222") do
      Signup::PhoneVerificationService.send_code!(PHONE)

      4.times do
        result = Signup::PhoneVerificationService.verify!(PHONE, "999999")
        assert_equal :mismatch, result.reason
      end
      verification = SignupVerification.find_by!(phone_number: PHONE)
      assert_equal 4, verification.attempts

      # 5회째 실패 — 이후로는 attempts_exceeded로 차단
      assert_equal :mismatch, Signup::PhoneVerificationService.verify!(PHONE, "999999").reason
      blocked = Signup::PhoneVerificationService.verify!(PHONE, "222222") # 정답이어도 차단
      assert_equal :attempts_exceeded, blocked.reason
      assert_not verification.reload.verified?
    end
  end

  test "REF-006 검증 이력이 없는 번호는 not_found로 거절된다" do
    assert_equal :not_found, Signup::PhoneVerificationService.verify!("01000000000", "123456").reason
  end

  test "REF-006 consume!은 검증 완료 레코드를 1회만 소비한다(원자·재사용 방지)" do
    with_fixed_verification_code("333333") do
      Signup::PhoneVerificationService.send_code!(PHONE)
      Signup::PhoneVerificationService.verify!(PHONE, "333333")

      consumed = Signup::PhoneVerificationService.consume!(PHONE)
      assert_not_nil consumed
      assert consumed.consumed?

      assert_nil Signup::PhoneVerificationService.consume!(PHONE) # 재사용 불가
    end
  end

  test "REF-006 consume!은 미검증·만료 레코드를 소비하지 않는다" do
    with_fixed_verification_code("444444") do
      verification = Signup::PhoneVerificationService.send_code!(PHONE).verification
      assert_nil Signup::PhoneVerificationService.consume!(PHONE) # 미검증

      verification.update!(verified_at: Time.current, expires_at: 1.minute.ago) # 만료
      assert_nil Signup::PhoneVerificationService.consume!(PHONE)
    end
  end
end

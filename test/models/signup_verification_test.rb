require "test_helper"

# 가입 휴대폰 인증 모델 테스트 (F10 — REF-006: 시도 제한·만료·소비 판정).
class SignupVerificationTest < ActiveSupport::TestCase
  test "전화번호 형식 검증 — 정규화 숫자 01x 형식만 허용" do
    record = SignupVerification.new(phone_number: "01012345678", code_digest: "digest",
                                    expires_at: 5.minutes.from_now)
    assert record.valid?

    record.phone_number = "99912345678"
    assert_not record.valid?
    assert record.errors[:phone_number].present?
  end

  test "전화번호는 deterministic 암호화로 저장된다(평문 없음 — TEN-003)" do
    SignupVerification.create!(phone_number: "01012340009", code_digest: "digest",
                               expires_at: 5.minutes.from_now)
    # 저장 컬럼은 암호문 — 평문이 raw 데이터에 없다
    raw = SignupVerification.connection.select_value(
      "SELECT phone_number FROM signup_verifications LIMIT 1"
    ).to_s
    assert_not_includes raw, "01012340009"
    # deterministic이므로 번호로 조회 가능
    assert SignupVerification.find_by(phone_number: "01012340009").present?
  end

  test "attempts_exhausted?는 5회 도달에서 true다(REF-006)" do
    record = SignupVerification.create!(phone_number: "01012340010", code_digest: "d",
                                        expires_at: 5.minutes.from_now, attempts: 4)
    assert_not record.attempts_exhausted?

    record.increment!(:attempts)
    assert record.reload.attempts_exhausted?
  end

  test "usable_for_signup?는 verified·미소비·미만료 조건을 모두 요구한다" do
    record = SignupVerification.create!(phone_number: "01012340011", code_digest: "d",
                                        expires_at: 5.minutes.from_now)
    assert_not record.usable_for_signup? # 미검증

    record.update!(verified_at: Time.current)
    assert record.usable_for_signup?

    record.update!(expires_at: 1.minute.ago) # 만료
    assert_not record.usable_for_signup?

    record.update!(expires_at: 5.minutes.from_now, consumed_at: Time.current) # 소비
    assert_not record.usable_for_signup?
  end
end

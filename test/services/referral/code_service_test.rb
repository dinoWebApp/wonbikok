require "test_helper"

# 추천 코드 서비스 테스트 (F10 — REF-001: 형식·유효기간·주간 로테이션·직원당 유효 1개).
class Referral::CodeServiceTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.create!(name: "코드직원", email: "svc-code@example.com",
                            password: "password123", role: "sales")
  end

  test "REF-001 발급 코드는 8자 대문자+숫자·7일 유효다" do
    code = Referral::CodeService.issue_for!(@rep)

    assert_equal 8, code.length
    assert_match(/\A[A-Z0-9]{8}\z/, code)
    issued = @rep.active_referral_code
    assert_in_delta 7.days.from_now, issued.expires_at, 5
  end

  test "REF-001 verify!는 유효 코드에 직원을 반환하고 만료·불일치에는 nil을 반환한다" do
    code = Referral::CodeService.issue_for!(@rep)

    assert_equal @rep.id, Referral::CodeService.verify!(code)&.id
    assert_equal @rep.id, Referral::CodeService.verify!(code.downcase)&.id # 대소문자 정규화
    assert_nil Referral::CodeService.verify!("WRONG123") # 불일치
    assert_nil Referral::CodeService.verify!("") # 공백

    ReferralCode.find_by(code: code).update!(expires_at: 1.minute.ago) # 만료
    assert_nil Referral::CodeService.verify!(code) # 만료 코드 가입 거절 근거(REF-001)
  end

  test "REF-001 재발급(로테이션)은 기존 유효 코드를 replaced하고 직원당 유효 1개를 유지한다" do
    first = Referral::CodeService.issue_for!(@rep)
    second = Referral::CodeService.issue_for!(@rep)

    assert_not_equal first, second
    assert_equal 1, @rep.referral_codes.live.count
    assert_equal second, @rep.active_referral_code.code
    # 이력 보존(만료 코드 삭제 금지) — 기존 코드 행은 replaced_at과 함께 남는다
    old = @rep.referral_codes.find_by(code: first)
    assert_not_nil old
    assert_not_nil old.replaced_at
    assert_nil Referral::CodeService.verify!(first) # 구 코드는 더 이상 유효하지 않다
  end

  test "REF-001 rotate_all!은 활성 직원 전원을 재발급하고 정지 직원은 제외한다" do
    other = SalesRep.create!(name: "다른직원", email: "svc-code2@example.com",
                             password: "password123", role: "officer")
    suspended = SalesRep.create!(name: "정지직원", email: "svc-code3@example.com",
                                 password: "password123", role: "sales")
    suspended.suspend!("정지 사유")

    first_a = Referral::CodeService.issue_for!(@rep)
    first_b = Referral::CodeService.issue_for!(other)
    Referral::CodeService.issue_for!(suspended) # 정지 전 코드 — 유지

    count = Referral::CodeService.rotate_all!

    assert_equal 2, count # 활성 2명만
    assert_equal 1, @rep.referral_codes.live.count
    assert_equal 1, other.referral_codes.live.count
    assert_not_equal first_a, @rep.active_referral_code.code
    assert_not_equal first_b, other.active_referral_code.code
    assert_equal 1, suspended.referral_codes.live.count # 정지 직원은 재발급 대상 제외
  end

  test "REF-007 정지 직원의 코드는 suspend!에 의해 무효화되어 verify!가 실패한다" do
    code = Referral::CodeService.issue_for!(@rep)
    @rep.suspend!("정지 조치")

    assert_nil Referral::CodeService.verify!(code)
  end
end

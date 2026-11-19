require "test_helper"

# 추천 코드 주간 로테이션 배치 테스트 (F10 — REF-001, recurring.yml 월요일 09:00).
# 발송 없는 배치 — 외부 호출 없음.
class ReferralCodeRotationJobTest < ActiveJob::TestCase
  test "주간 로테이션은 활성 직원 전원의 코드를 교체한다" do
    rep = SalesRep.create!(name: "로테이션직원", email: "rotation@example.com",
                           password: "password123", role: "sales")
    old_code = Referral::CodeService.issue_for!(rep)

    ReferralCodeRotationJob.perform_now

    assert_equal 1, rep.referral_codes.live.count
    assert_not_equal old_code, rep.active_referral_code.code
    assert_not_nil rep.referral_codes.find_by(code: old_code).replaced_at # 이력 보존
  end

  test "정지 직원은 로테이션 대상에서 제외된다(REF-007)" do
    rep = SalesRep.create!(name: "정지로테", email: "rotation-sus@example.com",
                           password: "password123", role: "sales")
    old_code = Referral::CodeService.issue_for!(rep)
    rep.suspend!("정지") # 유효 코드 즉시 무효화

    ReferralCodeRotationJob.perform_now

    assert_equal 0, rep.referral_codes.live.count # 무효화 후 신규 발급 없음(대상 제외)
    assert_nil Referral::CodeService.verify!(old_code)
    assert_equal 1, rep.referral_codes.count # 이력 행은 보존
  end

  test "recurring.yml에 월요일 09:00 스케줄이 등록되어 있다" do
    schedule = Rails.application.config_for(:recurring)&.dig(:referral_code_rotation) ||
               YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true)
                    .dig("production", "referral_code_rotation")

    assert_equal "ReferralCodeRotationJob", schedule["class"] || schedule[:class]
    assert_equal "0 9 * * 1", schedule["schedule"] || schedule[:schedule]
  end
end

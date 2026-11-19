require "test_helper"

# 추천 코드 모델 테스트 (F10 — REF-001: 유효성 판정·이력 보존).
class ReferralCodeTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.create!(name: "코드보유자", email: "code-owner@example.com",
                            password: "password123", role: "sales")
  end

  test "코드·만료시각은 필수이고 코드는 유니크다" do
    assert_raises(ActiveRecord::RecordInvalid) { ReferralCode.create!(sales_rep: @rep, code: "AB12CD34") }

    ReferralCode.create!(sales_rep: @rep, code: "AB12CD34", expires_at: 7.days.from_now)
    # 1차: 모델 유니크 검증(RecordInvalid) / 2차: DB 유니크 인덱스(마이그레이션 — REF-001 무결성)
    assert_raises(ActiveRecord::RecordInvalid) do
      ReferralCode.create!(sales_rep: @rep, code: "AB12CD34", expires_at: 7.days.from_now)
    end
    assert_equal 1, ReferralCode.where(code: "AB12CD34").count
  end

  test "active?는 replaced_at nil + 만료 전만 true다" do
    code = ReferralCode.create!(sales_rep: @rep, code: "ACTIVE01", expires_at: 7.days.from_now)
    assert code.active?

    code.update!(expires_at: 1.minute.ago) # 만료
    assert_not code.active?

    code.update!(expires_at: 7.days.from_now, replaced_at: Time.current) # 교체
    assert_not code.active?
  end

  test "live 스코프는 만료·교체 코드를 제외한다(REF-001 유효 검증 단일 경유)" do
    live = ReferralCode.create!(sales_rep: @rep, code: "LIVE0001", expires_at: 7.days.from_now)
    ReferralCode.create!(sales_rep: @rep, code: "EXPIRD01", expires_at: 1.minute.ago)
    ReferralCode.create!(sales_rep: @rep, code: "REPLC01", expires_at: 7.days.from_now,
                         replaced_at: Time.current)

    assert_equal [ live.id ], ReferralCode.live.ids
  end

  test "코드 형식은 8자 대문자+숫자다(REF-001 — CodeService 생성 결과)" do
    code = Referral::CodeService.issue_for!(@rep)
    assert_equal 8, code.length
    assert_match(/\A[A-Z0-9]{8}\z/, code)
  end
end

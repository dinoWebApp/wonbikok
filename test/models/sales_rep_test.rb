require "test_helper"

# 영업 직원 모델 테스트 (F10 — role 체계·유효 코드 1개·REF-007 suspend!·잠금).
class SalesRepTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.new(name: "김영업", email: "rep@example.com", password: "password123", role: "sales")
  end

  test "role 기본 수수료율·캡 — sales 20%·12개월 / officer 15%·무기한" do
    assert_equal BigDecimal("0.20"), @rep.effective_commission_rate
    assert_equal 12, @rep.effective_cap_months

    officer = SalesRep.new(name: "이오피서", email: "off@example.com", password: "password123",
                           role: "officer")
    assert_equal BigDecimal("0.15"), officer.effective_commission_rate
    assert_nil officer.effective_cap_months # 무기한
  end

  test "컬럼 지정값은 role 기본값보다 우선하며 0.05~0.30 범위 밖은 거절된다" do
    @rep.commission_rate = 0.25
    assert_equal BigDecimal("0.25"), @rep.effective_commission_rate

    @rep.commission_rate = 0.40
    assert_not @rep.valid?
    assert @rep.errors[:commission_rate].present?

    @rep.commission_rate = 0.04
    assert_not @rep.valid?

    @rep.commission_rate = 0.05 # 경계 허용
    assert @rep.valid?
    @rep.commission_rate = 0.30
    assert @rep.valid?
  end

  test "role·status는 허용값 외 거절된다(string 포함 검증)" do
    @rep.role = "intern"
    assert_not @rep.valid?
    assert @rep.errors[:role].present?

    @rep.role = "sales"
    @rep.status = "paused"
    assert_not @rep.valid?
    assert @rep.errors[:status].present?
  end

  test "이메일은 유니크·소문자 정규화된다" do
    @rep.email = "  MIXED@Example.COM "
    @rep.save!
    assert_equal "mixed@example.com", @rep.email

    duplicate = SalesRep.new(name: "중복", email: "MIXED@example.com", password: "password123",
                             role: "sales")
    assert_not duplicate.valid?
    assert duplicate.errors[:email].present?
  end

  test "유효 코드는 직원당 1개만 조회된다(active_referral_code)" do
    @rep.save!
    first = Referral::CodeService.issue_for!(@rep)
    second = Referral::CodeService.issue_for!(@rep) # 재발급 → 기존 코드 replaced

    live_codes = @rep.referral_codes.live
    assert_equal 1, live_codes.length
    assert_equal second, live_codes.sole.code
    assert_equal second, @rep.active_referral_code.code
    assert_not_equal first, second # 재발급은 새 코드
    # 이력 보존 — 만료·교체 코드는 삭제되지 않는다
    assert_equal 2, @rep.referral_codes.count
    assert_not_nil @rep.referral_codes.find_by(code: first).replaced_at
  end

  # REF-007: 정지는 사유 필수 + 유효 코드 즉시 무효화
  test "REF-007 suspend!는 사유 없이는 호출 불가고 유효 코드를 즉시 무효화한다" do
    @rep.save!
    code = Referral::CodeService.issue_for!(@rep)

    assert_raises(ArgumentError) { @rep.suspend!("") }

    @rep.suspend!("부당 사용 정지")
    assert @rep.suspended?
    assert_equal "부당 사용 정지", @rep.suspended_reason
    assert_nil @rep.active_referral_code # 코드 무효화
    assert_equal code, @rep.referral_codes.sole.code # 행은 이력 보존(삭제 아님)
    assert_not_nil @rep.referral_codes.sole.replaced_at
    assert Referral::CodeService.verify!(code).nil? # 검증도 실패(REF-001 경유)
  end

  test "정지 상태로 변경 시 사유가 없으면 검증이 거절한다(2차 방어)" do
    @rep.save!
    @rep.status = SalesRep::STATUS_SUSPENDED
    assert_not @rep.valid?
    assert @rep.errors[:suspended_reason].present?
  end

  test "resume!은 상태를 active로 되돌리고 사유를 지운다" do
    @rep.save!
    @rep.suspend!("정지 사유")
    @rep.resume!
    assert @rep.active?
    assert_nil @rep.suspended_reason
  end

  # 로그인 5회 실패 잠금(AdminUser 동일 규약)
  test "로그인 5회 실패 시 잠기고 해제 전까지 실패를 추가로 올리지 않는다" do
    @rep.save!
    5.times { @rep.register_failed_attempt! }
    assert @rep.locked?

    locked_now = @rep.register_failed_attempt!
    assert_not locked_now
    assert_equal 5, @rep.reload.failed_attempts

    @rep.reset_failed_attempts!
    assert_not @rep.reload.locked?
    assert_equal 0, @rep.failed_attempts
  end

  test "referred_tenants는 본인이 추천한 테넌트만 반환한다(REF-005 스코프 원천)" do
    @rep.save!
    mine = Tenant.create!(name: "내추천 학원", onboarding_step: 6,
                          referred_by_sales_rep: @rep)
    Tenant.create!(name: "무관 학원", onboarding_step: 6)

    assert_equal [ mine.id ], @rep.referred_tenants.ids
  end

  # W-4: 금전·코드 이력 보존 — 이력이 있는 rep 삭제는 예외로 차단(콘솔 사고 방어)
  test "코드·수수료 이력이 있는 rep의 삭제는 차단되고 이력이 보존된다" do
    @rep.save!
    Referral::CodeService.issue_for!(@rep)
    tenant = Tenant.create!(name: "이력보존 학원", onboarding_step: 6, referred_by_sales_rep: @rep)
    subscription = Subscription.create!(tenant: tenant, plan: :light, status: :active)
    Referral::CommissionService.accrue_on_payment!(subscription, 10_000)

    assert_raises(ActiveRecord::DeleteRestrictionError) { @rep.destroy }
    assert SalesRep.exists?(@rep.id)
    assert_equal 1, @rep.referral_codes.count
    assert_equal 1, @rep.commission_ledgers.count
  end
end

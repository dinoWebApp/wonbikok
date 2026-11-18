require "test_helper"

module Admin
  class TenantSearchServiceTest < ActiveSupport::TestCase
    setup do
      @gim = Tenant.create!(name: "김원장 학원", business_number: "1234567890", onboarding_step: 6)
      @park = Tenant.create!(name: "박수학 전문 학원", business_number: "9876543210", onboarding_step: 1)
      @percent = Tenant.create!(name: "100% 학원", business_number: "5555555555", onboarding_step: 1)
    end

    test "빈 쿼리는 전체 목록을 최근 가입순으로 반환한다" do
      result = Admin::TenantSearchService.new.call("")

      assert_includes result, @gim
      assert_equal @percent.id, result.first.id
    end

    test "상호 부분 일치로 검색한다" do
      result = Admin::TenantSearchService.new.call("김원장")

      assert_includes result, @gim
      assert_not_includes result, @park
    end

    test "사업자등록번호 부분 일치로 검색한다" do
      result = Admin::TenantSearchService.new.call("9876")

      assert_equal [ @park.id ], result.map(&:id)
    end

    test "교습소 ID(숫자)로 완전 일치 검색한다" do
      result = Admin::TenantSearchService.new.call(@gim.id.to_s)

      assert_equal [ @gim.id ], result.map(&:id)
    end

    test "숫자 쿼리는 ID 일치와 사업자번호 부분 일치를 OR로 결합한다" do
      result = Admin::TenantSearchService.new.call(@gim.id.to_s)
      assert_equal [ @gim.id ], result.map(&:id)

      # "5555"는 ID 일치 대상이 없어도 사업자번호 일치로 100% 학원을 찾는다
      result = Admin::TenantSearchService.new.call("5555")
      assert_equal [ @percent.id ], result.map(&:id)
    end

    test "LIKE 와일드카드는 이스케이프되어 패턴 주입으로 전체 조회되지 않는다" do
      result = Admin::TenantSearchService.new.call("%%")

      assert_not_includes result, @gim
      assert_not_includes result, @park
    end

    test "%가 포함된 상호는 이스케이프된 리터럴로 검색된다" do
      result = Admin::TenantSearchService.new.call("100%")

      assert_equal [ @percent.id ], result.map(&:id)
    end

    test "v1.0 축소 — 휴대폰번호 입력은 검색 대상이 아니다(암호화 컬럼 부분 일치 불가)" do
      # users.phone_number는 encrypts 저장이라 부분 일치 불가 — 후속 과제(03_implementation 보고서).
      # 휴대폰번호 형태 입력은 상호·사업자번호 어디에도 매칭되지 않는다.
      result = Admin::TenantSearchService.new.call("01012345678")

      assert result.empty?
    end
  end
end

require "test_helper"

class TenantTest < ActiveSupport::TestCase
  # WARNING-1: 온보딩 2스텝 사업자 정보 서버측 완결성
  test "사업자 정보 컨텍스트에서 필수 항목 누락은 무효다" do
    tenant = Tenant.new

    refute tenant.valid?(:business_info)
    %i[name business_number business_type owner_name].each do |attr|
      assert tenant.errors[attr].present?, "expected error on #{attr}"
    end
  end

  test "사업자 정보가 완비되면 business_info 컨텍스트가 유효하다" do
    tenant = Tenant.new(name: "완비 학원", business_number: "1234567890",
                        business_type: :academy, owner_name: "김원장")

    assert tenant.valid?(:business_info)
  end

  # F1: 사업자등록번호 형식 검증(하이픈 제거 10자리)
  test "사업자번호 9자리는 거절된다" do
    tenant = tenants(:one)
    tenant.business_number = "123456789"

    refute tenant.valid?
  end

  test "하이픈 포함 사업자번호는 10자리로 정규화되어 유효하다" do
    tenant = tenants(:one)
    tenant.business_number = "123-45-67890"
    assert tenant.valid?
    assert_equal "1234567890", tenant.business_number
  end

  # 온보딩 완료 판정 경계
  test "온보딩 완료 판정은 step 6부터다" do
    assert tenants(:one).onboarding_complete?
    refute tenants(:two).onboarding_complete?
  end
end

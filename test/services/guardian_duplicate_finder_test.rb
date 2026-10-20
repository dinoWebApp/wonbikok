require "test_helper"

class GuardianDuplicateFinderTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one)
    @student = create_student_with_guardian(tenant: @tenant, name: "김민준", phone_number: "01011112222")
    @finder = GuardianDuplicateFinder.new(@tenant)
  end

  # 중복 확인: 동일 보호자 전화
  test "동일 보호자 전화를 가진 기존 원생을 탐지한다" do
    conflicts = @finder.conflicts_with(name: "새원생", phone_number: "010-1111-2222")

    assert_includes conflicts.map(&:name), "김민준"
  end

  # 중복 확인: 유사 이름(공백 제거 후 포함 관계)
  test "유사 이름 기존 원생을 탐지한다" do
    conflicts = @finder.conflicts_with(name: "민준", phone_number: "01099998888")

    assert_includes conflicts.map(&:name), "김민준"
  end

  test "무관한 이름과 전화는 충돌로 판정하지 않는다" do
    conflicts = @finder.conflicts_with(name: "정다은", phone_number: "01088887777")

    assert_empty conflicts
  end

  # 형제 허용: 동일 전화 원생 묶음이 그룹으로 산출된다(등록 자체는 confirm 경로로 허용)
  test "동일 전화를 공유하는 형제 원생이 그룹으로 탐지된다" do
    create_student_with_guardian(tenant: @tenant, name: "김민서", phone_number: "01011112222")

    groups = @finder.sibling_groups

    assert_equal 1, groups.size
    assert_equal %w[김민준 김민서].sort, groups.first.map(&:name).sort
    assert_empty(@finder.sibling_student_ids - @tenant.students.reload.map(&:id))
  end

  test "형제가 없으면 그룹은 비어 있다" do
    assert_empty @finder.sibling_groups
  end
end

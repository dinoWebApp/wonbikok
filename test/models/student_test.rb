require "test_helper"

class StudentTest < ActiveSupport::TestCase
  # INV-004: 재원 원생만 청구 대상 스코프에 포함
  test "INV-004 Student.active는 재원 원생만 포함한다" do
    active_names = tenants(:one).students.active.map(&:name)

    assert_includes active_names, "정재원"
    assert_not_includes active_names, "이서윤"
    assert_not_includes active_names, "박도윤"
  end

  # INV-004 경계: 상태 전이 시 스코프 즉시 반영
  test "INV-004 휴원 전이 후 active 스코프에서 제외된다" do
    student = students(:one)
    student.update!(status: :paused)

    assert_not_includes Student.active.pluck(:id), student.id
  end

  # INV-004: 휴원·퇴원 시 ended_on 최초 기록
  test "휴원 시 ended_on이 기록된다" do
    student = students(:one)
    freeze_time
    student.update!(status: :paused)

    assert_equal Date.current, student.reload.ended_on
  ensure
    unfreeze_time
  end

  # INV-004: 재원 복원 시 ended_on 해제
  test "복원 시 ended_on이 해제된다" do
    student = students(:paused_one)
    assert_not_nil student.ended_on

    student.update!(status: :active)

    assert_nil student.reload.ended_on
  end

  # INV-004 경계: 최초 휴원일 보존(||=)
  test "재휴원 시 최초 ended_on이 보존된다" do
    student = students(:paused_one)
    original = student.ended_on

    student.save!

    assert_equal original, student.reload.ended_on
  end

  # PAY-DAY 경계: 허용 범위 1..28
  test "납부일 1과 28은 허용된다" do
    assert students(:one).update(payment_day: 1)
    assert students(:one).reload.update(payment_day: 28)
  end

  # PAY-DAY 경계: 0과 29는 거절
  test "납부일 0과 29는 거절된다" do
    refute students(:one).update(payment_day: 0)
    refute students(:one).reload.update(payment_day: 29)
    assert_not_nil students(:one).errors[:payment_day]
  end
end

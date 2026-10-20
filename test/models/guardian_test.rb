require "test_helper"

class GuardianTest < ActiveSupport::TestCase
  setup do
    @student = create_student_with_guardian(tenant: tenants(:one))
  end

  # TEN-003: DB에는 암호문만 저장된다
  test "TEN-003 phone_number는 DB에 평문이 아닌 암호문으로 저장된다" do
    guardian = @student.guardians.first
    raw = Guardian.connection.select_value(
      Guardian.sanitize_sql_array([ "SELECT phone_number FROM guardians WHERE id = ?", guardian.id ])
    )

    assert_not_nil raw
    assert_not_includes raw, "0101111"
  end

  # TEN-003: phone_last4가 평문 보조 컬럼으로 채워진다
  test "TEN-003 phone_last4가 저장 시 자동 채워진다" do
    guardian = @student.guardians.first

    assert_equal "2222", guardian.phone_last4
  end

  test "하이픈 포함 번호는 정규화되어 저장된다" do
    guardian = @student.guardians.create!(name: "아버님", phone_number: "010-5555-6666")

    assert_equal "01055556666", guardian.phone_number
  end

  # TEN-003 예외: 형식 위반 번호 거절
  test "형식에 맞지 않는 번호는 거절된다" do
    guardian = @student.guardians.build(name: "글로벌님", phone_number: "821012345678")

    refute guardian.valid?
    assert guardian.errors[:phone_number].present?
  end

  # TEN-003: masked_phone 형식 검증
  test "TEN-003 masked_phone은 010-****-1234 형식이다" do
    guardian = @student.guardians.first

    assert_equal "010-****-2222", masked_phone(guardian.phone_number)
    assert_not_includes masked_phone(guardian.phone_number), "1111"
  end

  private

  def masked_phone(phone_number)
    digits = phone_number.to_s.gsub(/[^0-9]/, "")
    "#{digits[0, 3]}-****-#{digits[-4, 4]}"
  end
end

require "test_helper"

class UserTest < ActiveSupport::TestCase
  # TEN-003: 전화번호 정규화
  test "하이픈 포함 번호가 정규화되어 저장된다" do
    _tenant, user = create_owner_user(phone_number: "010-3333-4444")

    assert_equal "01033334444", user.phone_number
  end

  # TEN-003: DB에는 평문이 아닌 암호문이 저장된다
  test "TEN-003 phone_number는 DB에 평문이 아닌 암호문으로 저장된다" do
    _tenant, user = create_owner_user
    raw = User.connection.select_value(
      User.sanitize_sql_array([ "SELECT phone_number FROM users WHERE id = ?", user.id ])
    )

    assert_not_includes raw, "0103333"
  end

  # TEN-003: deterministic 암호화로 번호 조회 가능(로그인 경로)
  test "TEN-003 동일 번호로 find_by 조회가 가능하다(deterministic)" do
    _tenant, user = create_owner_user

    assert_equal user.id, User.find_by(phone_number: "01033334444").id
  end

  test "비밀번호 7자는 거절되고 8자는 허용된다" do
    tenant = Tenant.create!(name: "비밀번호 학원")

    short = tenant.users.build(phone_number: "01012340001", password: "pass123")
    refute short.valid?
    assert short.errors[:password].present?

    ok = tenant.users.build(phone_number: "01012340002", password: "pass1234")
    assert ok.valid?
  end

  # 인증 예외: 중복 번호는 검증 단계에서 거절
  test "중복 번호 가입은 검증에서 거절된다" do
    create_owner_user

    assert_raises(ActiveRecord::RecordInvalid) do
      create_owner_user(phone_number: "01033334444")
    end
  end

  # 인증 예외 경계: 검증 우회 요청은 DB 유니크 인덱스에서 RecordNotUnique
  test "검증 통과 요청도 DB 유니크 제약에서 RecordNotUnique가 발생한다" do
    create_owner_user
    tenant = Tenant.create!(name: "레이스 학원")
    user = tenant.users.build(phone_number: "01033334444", password: "password123")

    with_validations_skipped(User) do
      assert_raises(ActiveRecord::RecordNotUnique) { user.save! }
    end
  end

  private

  # 유니크 레이스(WARNING-6) 재현용: 유효성 검사를 일시 생략해 DB 제약에 도달시킨다
  def with_validations_skipped(model)
    model.class_eval do
      alias_method :original_valid_without_skip, :valid?
      define_method(:valid?) { |*| true }
    end
    yield
  ensure
    model.class_eval do
      remove_method :valid?
      alias_method :valid?, :original_valid_without_skip
      remove_method :original_valid_without_skip
    end
  end
end

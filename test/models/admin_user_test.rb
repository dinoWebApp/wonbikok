require "test_helper"

class AdminUserTest < ActiveSupport::TestCase
  test "이메일·비밀번호로 생성한다" do
    admin = AdminUser.create!(email: "ops@example.com", password: "admin-pass-123")

    assert admin.persisted?
    assert_equal "ops@example.com", admin.email
    assert admin.authenticate("admin-pass-123")
  end

  test "이메일은 필수이고 형식을 검증한다" do
    assert_not AdminUser.new(email: nil, password: "admin-pass-123").valid?
    assert_not AdminUser.new(email: "not-an-email", password: "admin-pass-123").valid?
  end

  test "이메일은 유니크하다(대소문자 무시)" do
    AdminUser.create!(email: "ops@example.com", password: "admin-pass-123")

    duplicate = AdminUser.new(email: "OPS@EXAMPLE.COM", password: "admin-pass-123")
    assert_not duplicate.valid?
    assert duplicate.errors[:email].present?
  end

  test "생성 시 이메일이 정규화된다(공백 제거·소문자화)" do
    admin = AdminUser.create!(email: "  Ops@Example.COM ", password: "admin-pass-123")

    assert_equal "ops@example.com", admin.email
  end

  test "비밀번호는 8자 이상이다" do
    admin = AdminUser.new(email: "short@example.com", password: "short")

    assert_not admin.valid?
    assert admin.errors[:password].present?
  end

  test "실패 4회는 잠기지 않고 5회째에 잠긴다" do
    admin = AdminUser.create!(email: "lock@example.com", password: "admin-pass-123")

    4.times { admin.register_failed_attempt! }
    assert_not admin.locked?
    assert_equal 4, admin.failed_attempts

    locked_now = admin.register_failed_attempt!
    assert locked_now
    assert admin.locked?
    assert_not_nil admin.locked_at
  end

  test "잠긴 계정은 실패 카운트를 추가로 올리지 않는다(무한 잠금 갱신 방지)" do
    admin = AdminUser.create!(email: "lock2@example.com", password: "admin-pass-123")
    5.times { admin.register_failed_attempt! }
    attempts = admin.failed_attempts

    assert_not admin.register_failed_attempt!
    assert_equal attempts, admin.failed_attempts
  end

  test "로그인 성공 시 실패 카운트가 리셋된다" do
    admin = AdminUser.create!(email: "reset@example.com", password: "admin-pass-123")
    3.times { admin.register_failed_attempt! }

    admin.reset_failed_attempts!
    assert_equal 0, admin.failed_attempts
    assert_not admin.locked?
  end

  test "unlock!은 콘솔 해제용으로 잠금과 카운트를 초기화한다" do
    admin = AdminUser.create!(email: "unlock@example.com", password: "admin-pass-123")
    5.times { admin.register_failed_attempt! }
    assert admin.locked?

    admin.unlock!
    assert_not admin.locked?
    assert_equal 0, admin.failed_attempts
  end
end

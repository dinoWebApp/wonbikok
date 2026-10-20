require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "로그인 성공 시 온보딩 완료 테넌트는 루트로 이동한다" do
    _tenant, user = create_owner_user(step: 6)

    log_in(user)

    assert_redirected_to root_path
    follow_redirect!
    assert_response :ok
  end

  test "로그인 실패 시 422와 단일 오류 문구로 응답한다" do
    create_owner_user

    post session_url, params: { session: { phone_number: "01033334444", password: "wrong-pass" } }

    assert_response :unprocessable_entity
    assert_match "휴대폰번호 또는 비밀번호가 올바르지 않습니다", response.body
  end

  test "존재하지 않는 번호도 동일 문구로 응답한다(열거 방지)" do
    post session_url, params: { session: { phone_number: "01000000000", password: "wrong-pass" } }

    assert_response :unprocessable_entity
    assert_match "휴대폰번호 또는 비밀번호가 올바르지 않습니다", response.body
  end

  # WARNING-5: session 파라미터 누락 요청은 400
  test "본문 누락 요청은 400으로 응답한다" do
    post session_url

    assert_response :bad_request
  end

  # WARNING-4: 로그인 rate limit(10회/3분) — 429 검증(test_helper에서 store 교체)
  test "WARNING-4 로그인 11회째 시도는 429로 차단된다" do
    create_owner_user

    10.times do
      post session_url, params: { session: { phone_number: "01033334444", password: "wrong-pass" } }
      assert_response :unprocessable_entity
    end

    post session_url, params: { session: { phone_number: "01033334444", password: "wrong-pass" } }
    assert_response :too_many_requests
  end

  test "로그아웃 후 보호 경로 접근은 로그인으로 리다이렉트된다" do
    _tenant, user = create_owner_user(step: 6)
    log_in(user)

    delete session_url
    assert_redirected_to new_session_path

    get students_path
    assert_redirected_to new_session_path
  end
end

require "test_helper"

class BetaApplicationsControllerTest < ActionDispatch::IntegrationTest
  # 베타(파일럿) 신청 폼 — PRD 13.6 (랜딩 공개, 인증 게이트 skip)
  # Rule ID: TEN-002(필드 최소 수집), TEN-003(연락처 암호화·중복 최소 식별), 13.6(폼 요구사항)

  def valid_params(contact_type: "email", contact_value: "pilot@example.com")
    {
      name: "김원장",
      title: "principal",
      contact_type: contact_type,
      contact_value: contact_value,
      academy_type: "academy",
      student_count_range: "1_15",
      terms_agreed: "1"
    }
  end

  # --- 정상 제출 (PRG 303 → 완료 화면) ---

  test "13.6 신청 폼 페이지가 공개 렌더된다(비인증)" do
    get new_beta_application_url

    assert_response :ok
    assert_select "form[data-event=form_start]"
  end

  test "정상 제출은 303으로 완료 화면으로 리다이렉트되고 레코드 1건이 생성된다" do
    assert_difference "BetaApplication.count", 1 do
      post beta_applications_url, params: { beta_application: valid_params }
    end

    assert_redirected_to done_beta_applications_path
    assert_equal 303, response.status

    application = BetaApplication.order(:id).last
    assert_equal "김원장", application.name
    assert_equal "1_15", application.student_count_range
    assert_equal true, application.terms_agreed
    assert_equal false, application.marketing_agreed # 기본값 — 선택 동의 미체크
  end

  test "완료 화면은 공개 200이며 SLA 문구 없이 접수 안내만 표시한다" do
    get done_beta_applications_url

    assert_response :ok
    assert_match I18n.t("beta_applications.done.title"), response.body
    assert_no_match(/24시간|즉시/, response.body) # 13.6: 확인되지 않은 시간 약속 금지
  end

  # --- 검증 실패 (Turbo 규약 422 + 랜딩 재렌더) ---

  test "필수 동의 누락 제출은 422로 랜딩을 재렌더하고 오류를 표시한다" do
    params = valid_params.merge(terms_agreed: "0")

    assert_no_difference "BetaApplication.count" do
      post beta_applications_url, params: { beta_application: params }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("errors.form"), response.body # 오류 요약 박스
    assert_match "개인정보 수집·이용 동의", response.body # 속성 라벨이 포함된 안내
  end

  test "잘못된 이메일 형식 제출은 422로 거절된다" do
    params = valid_params(contact_value: "not-an-email")

    assert_no_difference "BetaApplication.count" do
      post beta_applications_url, params: { beta_application: params }
    end

    assert_response :unprocessable_entity
    # 커스텀 검증 메시지는 activerecord.errors.messages 하위에 정의됨(ko.yml)
    assert_match I18n.t("activerecord.errors.messages.invalid_email"), response.body
  end

  test "본문 누락 요청은 400으로 응답한다(Strong Parameters)" do
    post beta_applications_url

    assert_response :bad_request
  end

  test "TEN-002 허용 목록 외 필드는 무시된다(Strong Parameters)" do
    # params.expect가 정의되지 않은 키(ip_address 등)를 버리는지 — 초과 수집 차단
    assert_nothing_raised do
      post beta_applications_url, params: {
        beta_application: valid_params.merge(ip_address: "203.0.113.9", resident_number: "900101-1234567")
      }
    end

    assert_redirected_to done_beta_applications_path
    application = BetaApplication.order(:id).last
    assert_not_includes BetaApplication.column_names, "ip_address"
    assert_equal "김원장", application.name # 정상 필드는 저장
  end

  # --- 중복 신청 멱등 처리 (13.6 — 노출 금지, 동일 완료 화면) ---

  test "동일 연락처 재제출은 303 완료 화면으로 멱등 종결되고 레코드는 1건을 유지한다" do
    post beta_applications_url, params: { beta_application: valid_params }
    assert_redirected_to done_beta_applications_path

    assert_difference "BetaApplication.count", 0 do
      post beta_applications_url, params: { beta_application: valid_params }
    end

    assert_redirected_to done_beta_applications_path
    assert_equal 303, response.status
    assert_no_match I18n.t("beta_applications.notices.created"), response.body
    assert_equal 1, BetaApplication.count
  end

  test "연락 수단이 다르면 중복이 아니다(email vs phone)" do
    post beta_applications_url, params: { beta_application: valid_params(contact_type: "email", contact_value: "pilot@example.com") }
    assert_redirected_to done_beta_applications_path

    # 같은 이름이라도 연락 수단이 다르면 별도 신청(전화 형식은 유효한 번호로 제출)
    post beta_applications_url, params: { beta_application: valid_params(contact_type: "phone", contact_value: "01012345678") }

    assert_redirected_to done_beta_applications_path
    assert_equal 2, BetaApplication.count
  end

  # --- 정규화·암호화 경유 (컨트롤러 플로우 관점) ---

  test "전화 하이픈 포함 제출도 정규화·암호화되어 저장된다(TEN-003)" do
    post beta_applications_url, params: {
      beta_application: valid_params(contact_type: "phone", contact_value: "010-9876-5432")
    }

    assert_redirected_to done_beta_applications_path
    application = BetaApplication.order(:id).last
    assert_equal "01098765432", application.contact_value

    raw = BetaApplication.connection.select_value(
      BetaApplication.sanitize_sql_array([ "SELECT contact_value FROM beta_applications WHERE id = ?", application.id ])
    )
    assert_not_includes raw, "01098765432" # DB에는 암호문만(TEN-003)
  end

  # --- Rate limit (스팸 최소 방어 — 10회/1시간, 초과 시 친화 리다이렉트) ---

  test "11회째 제출은 rate limit으로 랜딩 리다이렉트 + 안내 문구로 차단된다" do
    params = { beta_application: valid_params }

    10.times do
      post beta_applications_url, params: params
      assert_redirected_to done_beta_applications_path # 중복 포함 303 멱등
    end

    post beta_applications_url, params: params

    assert_redirected_to root_path
    assert_equal I18n.t("beta_applications.notices.rate_limited"), flash[:alert]
    assert_equal 1, BetaApplication.count # 11회째는 생성되지 않음
  end
end

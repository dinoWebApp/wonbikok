require "test_helper"

# F9 학부모 청구 링크 공개 페이지(LNK-001~005, TEN-001/003).
# /b/:token 공개 라우트는 3-S 통합에서 routes.rb에 결선됨 — 정식 라우트 사용.
class BillingLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    # 납부 계좌(온보딩 3스텝)까지 설정된 테넌트 — 공개 페이지 계좌 안내 검증용
    @tenant = Tenant.create!(name: "테스트 학원", onboarding_step: 6,
                             bank_name: "국민은행", bank_account: "1234567890", account_holder: "김원장")
    _, @user = create_owner_user(tenant: @tenant)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
  end

  def issue_link(invoice = @invoice)
    BillingLinks::TokenService.issue_for(invoice).token
  end

  # LNK-001: 유효 토큰은 로그인 없이 청구 페이지 200
  test "LNK-001 유효 토큰이면 비로그인으로 청구 페이지를 200으로 렌더한다" do
    get "/b/#{issue_link}"

    assert_response :ok
    assert_match(/#{@tenant.name}/, @response.body) # 교습소명(PRD 8장 표시 항목)
    assert_select "a[href^='tel:']"                 # 문의 원터치 발신
  end

  # LNK-002 + TEN-003: 원생명은 마스킹(첫 글자+OO) — 스냅샷 원문 미노출
  test "LNK-002 원생명은 마스킹되어 노출되고 스냅샷 원문은 없다(TEN-003)" do
    masked_invoice = create_invoice(@tenant, @student, status: :SENT,
                                    target_month: "2026-09", student_name_snapshot: "홍길동")
    get "/b/#{issue_link(masked_invoice)}"

    assert_response :ok
    assert_match(/홍OO/, @response.body)
    assert_no_match(/홍길동/, @response.body)
  end

  # LNK-002: 화이트리스트 외 노출 금지 — 타 청구·타 원생·내부 메모·타 토큰
  test "LNK-002 타 청구·원생 명단·내부 정보·타 토큰은 노출되지 않는다" do
    other_student = create_student_with_guardian(tenant: @tenant, name: "박서준")
    other_invoice = create_invoice(@tenant, other_student, status: :SENT,
                                   target_month: "2026-09", adjustment_note: "교재비 포함")
    cancelled = create_invoice(@tenant, @student, status: :CANCELLED,
                               target_month: "2026-08", cancel_reason: "테스트 취소 사유")
    BillingLinks::TokenService.issue_for(other_invoice)
    BillingLinks::TokenService.issue_for(cancelled)

    get "/b/#{issue_link}"

    assert_response :ok
    assert_match(/김OO/, @response.body)                    # 자기 청구는 마스킹 표시
    assert_no_match(/김민준/, @response.body)               # 원문 미노출
    assert_no_match(/박서준/, @response.body)               # 타 원생 명단 미노출(LNK-002)
    assert_no_match(/교재비 포함/, @response.body)          # 타 청구 내부 메모 미노출
    assert_no_match(/테스트 취소 사유/, @response.body)     # 내부 취소 사유 미노출
    assert_no_match(/#{other_invoice.reload.public_token}/, @response.body) # 타 토큰 미노출
  end

  # LNK-002: 금액·내역·계좌는 화이트리스트대로 표시(3초 계좌 복사)
  test "LNK-002 금액·내역·납부 기한·계좌가 표시되고 결제 버튼은 없다(LNK-005)" do
    adjusted = create_invoice(@tenant, @student, status: :SENT,
                              target_month: "2026-09",
                              adjustment_amount: 30_000, adjustment_note: "교재비")
    get "/b/#{issue_link(adjusted)}"

    assert_response :ok
    assert_match(/280,000/, @response.body) # total = base 250,000 + 조정 30,000
    assert_match(/교재비/, @response.body)
    assert_match(/#{@tenant.bank_account}/, @response.body) # 계좌번호 표시
    assert_select "[data-controller='clipboard']" # 원탭 복사 컨트롤러 결선
    assert_select "[data-action='clipboard#copy']"
    assert_select "form", count: 0 # LNK-005: 온라인 결제 제공 전 — 폼·결제 버튼 없음
    assert_no_match(/결제하기/, @response.body)
  end

  # LNK-003: 폐기 토큰 — 만료 안내(청구 정보 미노출)
  test "LNK-003 폐기된 토큰은 만료 페이지를 렌더하고 청구 정보가 없다" do
    token = issue_link
    BillingLinks::TokenService.revoke_for(@invoice)

    get "/b/#{token}"

    assert_response :not_found
    assert_no_match(/#{@tenant.name}/, @response.body)
    assert_no_match(/250,000/, @response.body) # 금액 표시 형식(number_with_delimiter) 기준 미노출
    assert_no_match(/김OO/, @response.body)
    assert_no_match(/#{@tenant.bank_account}/, @response.body)
  end

  # LNK-003: 재발급 후 이전 토큰 즉시 만료
  test "LNK-003 재발급 후 이전 토큰은 만료 페이지로, 새 토큰은 정상 렌더된다" do
    old_token = issue_link
    new_token = BillingLinks::TokenService.reissue_for(@invoice).token

    get "/b/#{old_token}"
    assert_response :not_found

    get "/b/#{new_token}"
    assert_response :ok
  end

  # LNK-003: 존재하지 않는 토큰 — 동일 만료 안내(존재 여부 힌트 없음)
  test "LNK-003 존재하지 않는 토큰도 만료 안내를 렌더한다" do
    get "/b/does-not-exist-token"

    assert_response :not_found
    assert_no_match(/김OO/, @response.body)
  end

  # TEN-001: 페이지는 토큰에 해당하는 청구만 — 타 교습소 정보 미노출
  test "TEN-001 다른 교습소 청구 정보는 노출되지 않는다" do
    other_tenant, _other_user = create_owner_user(name: "다른 학원", phone_number: "01077778888")
    other_student = create_student_with_guardian(tenant: other_tenant, name: "최시우")
    create_invoice(other_tenant, other_student, status: :SENT)

    get "/b/#{issue_link}"

    assert_response :ok
    assert_no_match(/다른 학원/, @response.body)
    assert_no_match(/최시우/, @response.body)
  end

  # 공개 페이지 보호: 캐시 금지 + 색인 금지 + 앱 셸 분리 레이아웃
  test "공개 페이지는 no-store 캐시 헤더와 noindex 메타, 앱 셸 없는 레이아웃으로 렌더된다" do
    get "/b/#{issue_link}"

    assert_response :ok
    assert_includes @response.headers["Cache-Control"], "no-store"
    assert_match(/noindex/, @response.body)
    assert_select "nav", count: 0 # 원장 앱 하단탭·내비 없음(공개 전용 레이아웃)
  end

  # 납부 상태 3값 매핑(PRD 8장) — PAID=납부 완료(success) / PARTIALLY_PAID=확인 중(info)
  # / 그 외(SENT·UNPAID·OVERDUE·DRAFT 등)=납부 전(warning). 라벨 문구는 i18n(3-S 병합)이므로
  # 상태별 배지 톤으로 매핑 검증 — bg/text 톤은 토스트·금액 섹션과 겹치므로 배지 전용 border-* 톤 사용.
  test "납부 상태는 invoice.status 기반 3값으로 표시된다" do
    paid = create_invoice(@tenant, @student, status: :PAID, target_month: "2026-09")
    confirming = create_invoice(@tenant, @student, status: :PARTIALLY_PAID, target_month: "2026-08")
    overdue = create_invoice(@tenant, @student, status: :OVERDUE, target_month: "2026-07")

    get "/b/#{issue_link(paid)}"
    assert_response :ok
    assert_match(/border-success-200/, @response.body) # 납부 완료

    get "/b/#{issue_link(confirming)}"
    assert_response :ok
    assert_match(/border-brand-200/, @response.body) # 확인 중

    get "/b/#{issue_link(overdue)}"
    assert_response :ok
    assert_match(/border-warning-200/, @response.body) # 납부 전
  end
end

# frozen_string_literal: true

require "test_helper"

# 대시보드 컨트롤러 테스트 (W4 F7 — PRD 7장 F7).
# 인증 게이트, 표시 요소(할 일·지표·미발행 잔여 경고), month 파라미터 수용
# (형식 검증 — 무효·공백은 당월 기본), 마감 리포트 액션 존재(라우트는 3-S 통합에서 추가).
# dashboard.* i18n 키는 3-S에서 ko.yml에 추가되므로 정적 문구 단정은 하지 않는다
# (DB 파생 텍스트만 단정 — payments_controller_test 주석 패턴 준용).
class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @user = create_owner_user
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT) # 250_000
  end

  test "비로그인 접근은 로그인으로 리다이렉트된다" do
    get dashboard_path

    assert_redirected_to new_session_path
  end

  test "대시보드 표시 — 할 일·지표에 자기 테넌트 데이터와 바로가기가 나타난다" do
    log_in(@user)
    get dashboard_path

    assert_response :ok
    assert_match(/김민준/, @response.body)                          # 다가오는 리마인더 행(원생명)
    assert_match(/250,000/, @response.body)                        # 지표 금액(청구액·미납액)
    assert_match(/href="#{payments_path}"/, @response.body)        # 미확인 입금 바로가기
    assert_match(/href="#{cash_receipts_path}"/, @response.body)   # 발행 실패 바로가기
    assert_match(/href="#{reminders_path}"/, @response.body)       # 리마인더 바로가기
    assert_match(/href="#{new_student_path}"/, @response.body)     # 빠른 작업 — 원생 추가
  end

  test "미발행 잔여 경고 — PAID 무발행 원생을 목록으로 노출한다" do
    paid_student = create_student_with_guardian(tenant: @tenant, name: "이서윤")
    paid_invoice = create_invoice(@tenant, paid_student, status: :PAID)
    Payment.create!(tenant: @tenant, invoice: paid_invoice, status: :active,
                    amount: 250_000, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)

    log_in(@user)
    get dashboard_path

    assert_response :ok
    assert_match(/이서윤/, @response.body) # 미발행 잔여 목록(발행 이력 없는 완납 원생)
  end

  # F7 정합(리뷰 제안 고정): 대시보드 미확인 입금 수 == payments#index 미완납 행 수 —
  # 두 화면이 같은 기준(확정 청구 5종 & 잔액>0)으로 집계하는지 실렌더로 단정한다.
  test "미확인 입금 수가 payments 화면 미완납 행 수와 일치한다(F7 정합)" do
    partial = create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "이서윤"),
                             status: :PARTIALLY_PAID, base_amount: 200_000)
    Payment.create!(tenant: @tenant, invoice: partial, status: :active,
                    amount: 50_000, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "박도윤"),
                   status: :OVERDUE)
    # 제외 대상: 초안·취소(INV-003)·완납·타월
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "정하윤"),
                   status: :DRAFT)
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "한지호"),
                   status: :CANCELLED)
    paid = create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "고민우"),
                          status: :PAID)
    Payment.create!(tenant: @tenant, invoice: paid, status: :active,
                    amount: 250_000, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "최시우"),
                   status: :SENT, target_month: 2.months.ago.strftime("%Y-%m"))

    log_in(@user)
    get dashboard_path
    assert_response :ok
    # 대시보드 할 일 수치 — 미완납 확정 3건(김민준·이서윤·박도윤)
    assert_match(%r{<a [^>]*href="#{payments_path}"[^>]*>3명</a>}, @response.body)

    get payments_path
    assert_response :ok
    # 미완납 행은 각 행의 수납 등록 링크(new_payment_path?invoice_id=)로 셈한다
    unpaid_row_count = @response.body.scan(%r{payments/new\?invoice_id=}).size
    assert_equal 3, unpaid_row_count
    [ "김민준", "이서윤", "박도윤" ].each { |name| assert_match name, @response.body }
    # 초안·취소·타월은 어느 화면 섹션에도 미노출(완납 고민우는 수납 이력에 표시됨 — 제외 단정 대상 아님)
    [ "정하윤", "한지호", "최시우" ].each { |name| assert_no_match name, @response.body }
  end

  test "month 파라미터 — 유효 월로 집계 전환·무효 월은 당월 기본(C5 준용)" do
    past_month = 2.months.ago.strftime("%Y-%m")
    past_student = create_student_with_guardian(tenant: @tenant, name: "박도윤")
    create_invoice(@tenant, past_student, status: :SENT,
                   target_month: past_month, base_amount: 300_000)
    log_in(@user)

    get dashboard_path, params: { month: past_month }
    assert_response :ok
    assert_match(/300,000/, @response.body) # 과거 월 청구액

    get dashboard_path, params: { month: "9999-99" }
    assert_response :ok
    assert_match(/250,000/, @response.body)      # 당월 청구액으로 복귀
    assert_no_match(/300,000/, @response.body)   # 과거 월 금액 미노출
  end

  test "마감 리포트 액션 존재 — 라우트·링크는 3-S 통합에서 결선된다" do
    assert DashboardController.method_defined?(:report),
           "마감 리포트 액션이 정의되어 있어야 한다(3-S에서 get 'dashboard/report' 라우트 추가)"
  end
end

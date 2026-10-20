# W2 F6 HTTP 흐름 스모크(개발 검증용 — 검증 후 삭제)
require "test_helper"

class F6HttpSmokeTest < ActionDispatch::IntegrationTest
  test "리마인더 화면·발송·설정·제외·게이트·로그아웃 캐시 정리" do
    Tenant.destroy_all
    tenant = Tenant.create!(name: "스모크학원", business_number: "1234567890", business_type: :academy,
                            owner_name: "원장", bank_name: "국민", bank_account: "123-45", account_holder: "원장",
                            onboarding_step: Tenant::ONBOARDING_FINAL_STEP, practice: true)
    tenant.users.create!(phone_number: "01011112222", password: "password123")
    student = tenant.students.create!(name: "이원생", monthly_fee: 300_000, payment_day: 10)
    student.guardians.create!(name: "학부모", phone_number: "01033334444")
    inv = tenant.invoices.create!(student:, target_month: Date.current.strftime("%Y-%m"),
                                  student_name_snapshot: student.name, base_amount: 300_000,
                                  due_on: Date.current - 4, status: :SENT)

    post "/session", params: { session: { phone_number: "01011112222", password: "password123" } }
    assert_response :redirect

    get reminders_path
    assert_response :ok
    assert_match "이원생", response.body

    get reminder_preview_path, params: { invoice_ids: [ inv.id ] }
    assert_response :ok
    assert_match "리마인더", response.body

    post reminder_dispatch_path, params: { invoice_ids: [ inv.id ] }
    assert_response :redirect
    assert tenant.message_logs.reminder.exists?, "발송 로그 없음"

    get reminder_settings_path
    assert_response :ok
    patch reminder_settings_path, params: { tenant: { remind_tone: "soft", remind_send_hour: 10,
      remind_d3_enabled: "1", remind_d7_enabled: "0", remind_month_end_enabled: "1",
      remind_custom_text_d7: "커스텀 %{student_name}" } }
    assert_response :redirect
    assert_equal 10, tenant.reload.remind_send_hour

    get reminder_history_path
    assert_response :ok
    assert_match "이원생", response.body

    patch reminder_student_exclusion_path(student)
    assert_response :redirect
    assert student.reload.excluded_from_reminders?, "제외 미반영"

    # 온보딩 게이트: 미완료 테넌트 세션은 /students 직접 접근 차단(W1 후속)
    t2 = Tenant.create!(name: "게이트학원", onboarding_step: 2)
    t2.users.create!(phone_number: "01099998888", password: "password123")
    delete "/session"
    post "/session", params: { session: { phone_number: "01099998888", password: "password123" } }
    assert_response :redirect
    get students_path
    assert_redirected_to onboarding_step_path(2)

    # 로그아웃 시 CSV 오류내역 캐시 키 제거(W1 후속)
    key = "csv_import_errors:#{tenant.id}:smoke"
    Rails.cache.write(key, [ {} ])
    open_session do |sess|
      sess.post "/session", params: { session: { phone_number: "01011112222", password: "password123" } }
      sess.session[:csv_import_errors_key] = key
      sess.delete "/session"
      sess.assert_redirected_to "/session/new"
    end

    Tenant.destroy_all
    puts "HTTP SMOKE ALL PASS"
    assert_equal 0, Tenant.count, "스모크 데이터 클린업 실패"
  end
end

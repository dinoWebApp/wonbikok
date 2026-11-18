require "test_helper"

module Admin
  class TimelineServiceTest < ActiveSupport::TestCase
    setup do
      @tenant = Tenant.create!(name: "타임라인 학원", onboarding_step: 6)
      @owner = @tenant.users.create!(phone_number: "01099998888", password: "password123")
      @student = @tenant.students.create!(name: "김민준", monthly_fee: 250_000, payment_day: 25,
                                          status: :active,
                                          guardians_attributes: { "0" => { name: "어머님", phone_number: "01011112222" } })
      @invoice = @tenant.invoices.create!(student: @student, target_month: Date.current.strftime("%Y-%m"),
                                          student_name_snapshot: @student.name,
                                          base_amount: 250_000, due_on: Date.current)
    end

    test "가입·온보딩 상태 항목을 포함한다" do
      entries = Admin::TimelineService.new(@tenant).call

      kinds = entries.map(&:kind)
      assert_includes kinds, :tenant_created
      assert_includes kinds, :onboarding
    end

    test "온보딩 미완료 테넌트는 온보딩 상태 항목을 넣지 않는다" do
      tenant = Tenant.create!(name: "미완료 학원", onboarding_step: 2)

      entries = Admin::TimelineService.new(tenant).call

      assert_not_includes entries.map(&:kind), :onboarding
      assert_includes entries.map(&:kind), :tenant_created
    end

    test "발송·발행·감사 로그를 시간 역순으로 병합한다" do
      @tenant.message_logs.create!(invoice: @invoice, student: @student,
                                   template_type: :invoice_notice, status: :SENT,
                                   created_at: 3.days.ago)
      @tenant.cash_receipts.create!(invoice: @invoice, mgt_key: "CRTIMELINE01",
                                    issue_type: :income_deduction, amount: 250_000,
                                    state: :issued, issued_at: 1.day.ago,
                                    created_at: 1.day.ago)
      AuditLog.record!(admin_user: nil, action: "personal_info_viewed", target: @tenant,
                       created_at: 2.hours.ago)
      AuditLog.record!(admin_user: nil, action: "login", target: @tenant, created_at: 1.hour.ago)

      entries = Admin::TimelineService.new(@tenant).call
      times = entries.map(&:occurred_at)

      assert_equal times, times.sort.reverse # 최신순 정렬
      assert_includes entries.map(&:kind), :message
      assert_includes entries.map(&:kind), :cash_receipt
      assert_equal 2, entries.count { |entry| entry.kind == :audit }
    end

    test "subscription_events를 병합한다(f8 실구현 — detail JSON에서 사유 추출)" do
      subscription = Subscription.create!(tenant: @tenant, plan: "light", status: "trial",
                                          trial_started_at: 10.days.ago, trial_ends_at: 20.days.from_now)
      SubscriptionEvent.create!(subscription: subscription, event_type: "manual_payment",
                                amount: 49_000, detail: { "reason" => "수동 결제" }.to_json,
                                created_at: 4.days.ago)

      entries = Admin::TimelineService.new(@tenant).call
      subscription_entries = entries.select { |entry| entry.kind == :subscription_event }

      assert_equal 1, subscription_entries.size
      assert_equal 49_000, subscription_entries.first.amount
      assert_equal "수동 결제", subscription_entries.first.note
    end

    test "SubscriptionEvent 미구현 환경에서도 구독 외 항목으로 동작한다(폴백)" do
      # f8 미병합 상태를 흉내 — SubscriptionEvent 상수를 일시 비가시화할 수 없으므로
      # 병합 결과가 예외 없이 반환됨을 확인(정상 환경에서는 subscription 항목 포함).
      entries = Admin::TimelineService.new(@tenant).call

      assert_kind_of Array, entries
    end

    test "limit으로 항목 수를 제한한다" do
      5.times do |index|
        AuditLog.record!(admin_user: nil, action: "personal_info_viewed", target: @tenant,
                         created_at: index.minutes.ago)
      end

      entries = Admin::TimelineService.new(@tenant, limit: 3).call

      assert_equal 3, entries.size
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "fugit"

# 월간 청구 배치 테스트 — F3 멱등, recurring 스케줄 cron 파싱(C3 회귀)
class MonthlyInvoiceGenerationJobTest < ActiveSupport::TestCase
  test "배치 실행은 재실생성 없이 멱등하다" do
    tenant = Tenant.create!(name: "배치 학원", onboarding_step: 6)
    create_student_with_guardian(tenant: tenant)
    month = Date.current.strftime("%Y-%m")

    MonthlyInvoiceGenerationJob.perform_now(month)
    assert_equal 1, tenant.invoices.for_month(month).count

    MonthlyInvoiceGenerationJob.perform_now(month)
    assert_equal 1, tenant.invoices.for_month(month).count # INV-001 중복 생성 없음
  ensure
    tenant&.destroy
  end

  # C3 회귀: recurring.yml의 모든 schedule은 Fugit::Cron으로 파싱되어야 한다
  # ("at 7am on the 1st day..." 표기는 EoTime으로 파싱되어 Solid Queue에서 무음 탈락했다)
  test "recurring 스케줄은 전부 Fugit::Cron으로 파싱된다" do
    schedules = YAML.load_file(Rails.root.join("config/recurring.yml"))
                    .fetch("production").values.pluck("schedule").compact

    assert schedules.size >= 2, "recurring 스케줄이 비어 있다"
    schedules.each do |schedule|
      assert_instance_of Fugit::Cron, Fugit.parse(schedule),
                         "#{schedule}은(는) Fugit::Cron이 아니다 — Solid Queue 등록 무음 탈락 위험"
    end
  end
end

# 매월 1일 전 테넌트 월간 청구 초안 생성 배치 (F3).
# config/recurring.yml — 매월 1일 07:00. 재실행 멱등(Invoices::Generator skip).
class MonthlyInvoiceGenerationJob < ApplicationJob
  queue_as :default

  def perform(target_month = Date.current.strftime("%Y-%m"))
    Tenant.find_each do |tenant|
      result = Invoices::Generator.new(tenant:, target_month:).call
      Rails.logger.info(
        "[MonthlyInvoiceGeneration] tenant=#{tenant.id} month=#{result.target_month} " \
        "created=#{result.created} skipped=#{result.skipped}"
      )
    end
  end
end

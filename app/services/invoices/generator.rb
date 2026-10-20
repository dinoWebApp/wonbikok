# 월간 청구 초안 생성 (F3). 배치(MonthlyInvoiceGenerationJob)와 수동 트리거 공용.
# - TEN-004: 확정 시점 스냅샷 — 원생명·기본 원비를 복제해 보관
# - INV-004: Student.active(재원)만 대상 — 휴원·퇴원 자동 제외
# - INV-001: 기존 존재 건은 skip(멱등) — 재실행해도 중복 생성 없음
class Invoices::Generator
  Result = Data.define(:target_month, :created, :skipped, :excluded) do
    def total_targets
      created + skipped
    end
  end

  def initialize(tenant:, target_month: nil, date: Date.current)
    @tenant = tenant
    @date = date
    @target_month = (target_month || date.strftime("%Y-%m")).to_s
  end

  def call
    created = 0
    skipped = 0

    @tenant.students.active.order(:id).find_each do |student| # INV-004
      invoice = @tenant.invoices.new(
        student:,
        target_month: @target_month,
        student_name_snapshot: student.name, # TEN-004 스냅샷
        base_amount: student.monthly_fee.to_i,
        due_on: due_on_for(student)
      )

      if invoice.save
        created += 1
      elsif invoice.errors.of_kind?(:student_id, :taken)
        skipped += 1 # INV-001: 이미 존재하는 청구 — 멱등 skip
      else
        invoice.errors.full_messages.each { |m| Rails.logger.warn("[Invoices::Generator] #{m}") }
      end
    end

    Result.new(target_month: @target_month, created:, skipped:, excluded: excluded_active_count)
  end

  private

  # 납부기한: 원생 payment_day 기반 당월 (1~28일, W1 Student::PAYMENT_DAY_RANGE)
  def due_on_for(student)
    day = student.payment_day.to_i.clamp(Student::PAYMENT_DAY_RANGE.min, Student::PAYMENT_DAY_RANGE.max)
    Date.parse("#{@target_month}-#{format('%02d', day)}")
  end

  def excluded_active_count
    @tenant.students.where.not(status: :active).count
  end
end

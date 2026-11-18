# 입금 매칭 힌트 (W3 F4 — PAY-003): 금액·원생명 기반 '추천' 후보 계산 전용.
# 반환은 후보 목록만 — 자동 선택·기본 선택 상태 개념이 없다(최종 판단은 원장,
# 컨트롤러·뷰도 pre-select를 만들지 않는다).
# 대상: 당월 확정 청구 중 미완납(초안·취소 제외 — INV-003, PAID 제외 — PAY-001).
class Payments::MatchingHintService
  # matched_on: :amount(청구 총액과 정확 일치) | :name(원생명 포함)
  Candidate = Data.define(:invoice, :matched_on)

  def initialize(tenant:, month: Date.current.strftime("%Y-%m"))
    @tenant = tenant
    @month = month.to_s
    @month = Date.current.strftime("%Y-%m") unless @month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
  end

  def suggest(amount: nil, name: nil)
    scope = unpaid_confirmed_invoices
    by_id = {}

    if amount.to_i.positive?
      scope.select { |invoice| invoice.total_amount == amount.to_i }.each do |invoice|
        by_id[invoice.id] = Candidate.new(invoice: invoice, matched_on: :amount)
      end
    end

    if name.present?
      scope.select { |invoice| invoice.student_name_snapshot.include?(name) }.each do |invoice|
        by_id[invoice.id] ||= Candidate.new(invoice: invoice, matched_on: :name)
      end
    end

    by_id.values # 금액 일치 후보 우선, 중복 제거 — 반환은 후보 목록만(선택은 원장)
  end

  private

  # 미완납 확정 청구 — READY/SENT/UNPAID/OVERDUE/PARTIALLY_PAID 중 active 수납 합계 < 총액
  # (READY 포함 — payments#index 표시 조건과 일치. 발송 전 선입금 건도 힌트에 등장)
  def unpaid_confirmed_invoices
    invoices = @tenant.invoices
                      .where(target_month: @month,
                             status: [ :READY, :SENT, :UNPAID, :OVERDUE, :PARTIALLY_PAID ])
                      .order(:id)
    paid_totals = Payment.active.where(invoice_id: invoices.ids).group(:invoice_id).sum(:amount)
    invoices.select { |invoice| paid_totals.fetch(invoice.id, 0) < invoice.total_amount }
  end
end

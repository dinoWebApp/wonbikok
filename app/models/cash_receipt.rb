# 현금영수증 (PRD 7장 F5, 9.2 상태 모델 — 바로빌 발급대행).
# CR-001: mgt_key(원생×당월×발급유형 파생, 24자 이내) 유니크로 발행 유일성·멱등 강제.
# CR-003: barobill_state 3000(국세청 전송 완료) 확인 전에는 issued로 전이 금지.
# TEN-002: 주민등록번호(13자리 숫자) 수집·저장 금지 — 검증으로 거절.
# TEN-003: identity_num은 암호화 저장, 화면 표시는 마스킹 메서드 경유.
class CashReceipt < ApplicationRecord
  # PRD 9.2 — 상태 7종
  enum :state, {
    needs_info: "needs_info",       # 발급 식별번호 등 필수 정보 미비
    pending: "pending",             # 발행 대기(큐)
    processing: "processing",       # 공급자 요청 완료, 최종 응답 대기
    issued: "issued",               # 발행 완료(승인번호 수령)
    failed: "failed",               # 발행 실패(재시도 대상)
    cancel_pending: "cancel_pending", # 취소 요청 중
    cancelled: "cancelled"          # 취소 완료
  }, validate: true

  enum :issue_type, {
    income_deduction: "income_deduction", # 소득공제용(보호자 휴대폰번호 기준)
    expense_evidence: "expense_evidence"  # 지급증명용(학부모 사업자번호 기준)
  }, validate: true

  # mgt_key 발급유형 축약 — 24자 제한 내 파생 키 구성용
  ISSUE_TYPE_ABBR = { income_deduction: "ID", expense_evidence: "EE" }.freeze

  belongs_to :tenant
  belongs_to :invoice

  encrypts :identity_num

  validates :mgt_key, presence: true, uniqueness: true # CR-001(DB 유니크 인덱스 병행)
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :cancel_reason, presence: true, if: -> { cancel_pending? || cancelled? }
  validate :identity_num_format # TEN-002
  validate :trade_date_within_d_minus_one, on: :create # W1: 생성 시 항상 적용(데드 컨텍스트 :issue 제거)

  scope :for_month_of, ->(invoice) { joins(:invoice).where(invoices: { target_month: invoice.target_month }) }

  # CR-001 멱등키: "CR" + invoice_id + YYYYMM + 발급유형 축약 (14자 — 24자 제한 내)
  def self.build_mgt_key(invoice, issue_type)
    "CR#{invoice.id}#{invoice.target_month.delete('-')}#{ISSUE_TYPE_ABBR.fetch(issue_type.to_sym)}"
  end

  # CR-005: 취소는 원본 발행과 연결된 별도 취소거래 건(CancelMgtKey)
  def build_cancel_mgt_key
    "CRC#{mgt_key}"
  end

  # TEN-003: 목록·상세 표시용 마스킹(뒤 4자리만 노출)
  def masked_identity_num
    return nil if identity_num.blank?

    "********#{identity_num.last(4)}"
  end

  # CR-003: 공급자 최종 상태(barobill_state 3000) 확인 시에만 issued 전이 허용
  def mark_issued!(nts_confirm_num:, barobill_state: 3000, nts_confirm_message: nil)
    return false unless processing?

    update!(
      state: :issued,
      nts_confirm_num: nts_confirm_num,
      nts_confirm_message: nts_confirm_message,
      barobill_state: barobill_state,
      issued_at: Time.current
    )
  end

  def mark_failed!(error)
    update!(state: :failed, last_error: error.to_s.truncate(255))
  end

  def mark_processing!
    return false unless pending? || failed?

    update!(state: :processing)
  end

  # 수취인 식별번호 확정 — 미비 시 needs_info로 분기(9.2)
  def resolve_identity_num!
    guardian = invoice.student.primary_guardian
    identified = if income_deduction?
                   guardian&.phone_number
    else
                   guardian&.business_number
    end

    if identified.present?
      update!(identity_num: identified, state: :pending)
    else
      update!(state: :needs_info)
    end
  end

  def retryable?
    failed? || needs_info? # C6: needs_info 보완 후 재시도 경로(9.2 상태 머신 복귀)
  end

  # C4(TEN-003): 처리자 휴대폰번호 원문 저장 금지 — 마스킹 후 저장(처리자·시간 기록 요구 유지)
  def issued_by=(value)
    raw = value.to_s
    masked = raw.match?(/\A01[016789]\d{7,8}\z/) ? "#{raw[0, 3]}-****-#{raw[-4, 4]}" : value
    super(masked)
  end

  def cancellable?
    issued?
  end

  private

  # TEN-002: 주민등록번호 형태(13자리 숫자) 입력은 거절.
  # 소득공제=휴대폰번호 / 지급증명=사업자등록번호만 허용(PRD 10.2·15.1).
  def identity_num_format
    return if identity_num.blank?

    normalized = identity_num.to_s.gsub(/[^0-9]/, "")
    errors.add(:identity_num, :resident_number_forbidden) if normalized.length == 13
  end

  # 바로빌 제약(PRD 10.2): TradeDate는 D-1까지만 — 전월 소급 발행 불가
  def trade_date_within_d_minus_one
    return if trade_date.blank?

    min_date = Date.current - 1.day
    return if trade_date.to_date.between?(min_date, Date.current)

    errors.add(:trade_date, :trade_date_too_old)
  end
end

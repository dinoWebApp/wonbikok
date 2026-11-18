# F9 학부모 청구 링크 공개 페이지(PRD 8장) — 비로그인·토큰 검증(LNK-001)·노출 최소(LNK-002).
# 원장 앱 셸과 분리된 공개 전용 레이아웃(billing_link) 사용.
class BillingLinksController < ApplicationController
  skip_before_action :require_authentication      # 학부모는 로그인 없이 링크로 진입(LNK)
  skip_before_action :ensure_onboarding_complete  # Current.tenant 의존 게이트 제외(비로그인)

  layout "billing_link"

  before_action :set_billing_view, only: :show
  before_action :disallow_storing, only: :show

  # LNK-003: 만료·폐기·불일치 토큰은 청구 정보 없이 원장 문의 안내만 렌더한다.
  # (404 — 토큰에 해당하는 리소스는 더 이상 존재하지 않음. 뷰는 학부모 친화 만료 안내.)
  def show
    render :expired, status: :not_found unless @billing
  end

  private

  # LNK-001/003: 유효(미폐기) 토큰만 통과 — 나머지는 nil로 만료 렌더.
  def set_billing_view
    invoice = BillingLinks::TokenService.find_active_by_token(params[:token])
    @billing = invoice && build_billing_view(invoice)
  end

  # 공개 링크의 뒤로가기·공유 기기 캐시 정보 보호 — 브라우저·프록시 저장 금지.
  def disallow_storing
    response.set_header("Cache-Control", "no-store, max-age=0")
  end

  # LNK-002 노출 화이트리스트 — 뷰에는 아래 13개 필드만 전달한다.
  # @invoice를 뷰에 넘기지 않고 Struct로 조립해 실수로 인한 내부 필드 노출 여지를 차단한다.
  # 절대 미포함: 전체 원생 명단·타 청구·내부 메모(cancel_reason 등)·공급자 원본 응답·토큰.
  BillingView = Data.define(
    :academy_name, :contact_phone,
    :student_name, :billing_month,
    :base_amount, :adjustment_amount, :adjustment_note, :total_amount,
    :due_on, :payment_state,
    :bank_name, :bank_account, :account_holder
  )

  def build_billing_view(invoice)
    tenant = invoice.tenant
    BillingView.new(
      academy_name: tenant.name,
      contact_phone: director_phone(tenant),
      student_name: masked_student_name(invoice.student_name_snapshot),
      billing_month: invoice.target_month,
      base_amount: invoice.base_amount.to_i,
      adjustment_amount: invoice.adjustment_amount.to_i,
      adjustment_note: invoice.adjustment_note.presence,
      total_amount: invoice.total_amount,
      due_on: invoice.due_on,
      payment_state: payment_state(invoice),
      bank_name: tenant.bank_name.presence,
      bank_account: tenant.bank_account.presence,
      account_holder: tenant.account_holder.presence
    )
  end

  # 납부 상태 3값 매핑(PRD 8장: 납부 전/확인 중/납부 완료) — invoice.status 기준만 표시.
  # 현금영수증 공급자 처리 상태(CashReceipt)는 이 페이지에 노출하지 않는다.
  PAYMENT_STATES = {
    "PAID" => :paid,
    "PARTIALLY_PAID" => :confirming
  }.freeze
  private_constant :PAYMENT_STATES

  def payment_state(invoice)
    PAYMENT_STATES.fetch(invoice.status, :pending) # DRAFT/READY/SENT/UNPAID/OVERDUE/CANCELLED → 납부 전
  end

  # 원장 문의 전화 — 원장 계정 휴대폰번호, 없으면 사업장 전화 보완. 둘 다 없으면 뷰에서 문의 블록 숨김.
  def director_phone(tenant)
    tenant.users.order(:created_at).first&.phone_number.presence || tenant.biz_tel.presence
  end

  # TEN-003: 공개 페이지 원생명 마스킹 — 첫 글자 + OO (예: 김민준 → 김OO)
  def masked_student_name(name)
    return "" if name.blank?

    "#{name[0]}OO"
  end
end

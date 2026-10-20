# frozen_string_literal: true

module Solapi
  # F3 본문 템플릿 치환 (PRD 7장 F3 본문 구조: 원생명·청구월·금액·계좌·기한·원장상호·원장전화).
  # W2 경계: 청구 링크(F9, W3) 없이 본문만으로 납부 정보 완결.
  # - 알림톡: 카카오 사전등록 템플릿의 #{변수} 치환값만 전달(템플릿 코드는 운영 주입 파라미터)
  # - SMS/LMS 폴백: 본문 직접 생성 — 90바이트 초과 시 LMS(subject 부여)
  class MessageBuilder
    SMS_MAX_BYTES = 90 # 솔라피 SMS 단문 90바이트(한글 45자) — 초과분은 LMS

    class << self
      # invoice_notice 메시지 해시(Solapi::Client#send_messages 입력 형식)
      def invoice_notice(invoice:, tenant:, to:, template_id: nil, pf_id: nil)
        config = Rails.application.config_for(:solapi)
        new(
          invoice:,
          tenant:,
          template_type: :invoice_notice,
          template_id: template_id.presence || config.dig(:kakao, :templates, :invoice_notice),
          pf_id: pf_id.presence || config.dig(:kakao, :pf_id)
        )
      end

      # F6 리마인더 — 단계(reminder_d3/d7/month_end)별 템플릿.
      # 문구: 원장 커스텀 문구 우선, 없으면 톤(부드러움/표준/공식) 기본 템플릿.
      # MSG-005: 원장상호·원장전화를 본문에 포함해 발신자 표기를 원장 기준으로 유지.
      def reminder(invoice:, tenant:, template_type:, to:, template_id: nil, pf_id: nil)
        config = Rails.application.config_for(:solapi)
        new(
          invoice:,
          tenant:,
          template_type:,
          template_id: template_id.presence || config.dig(:kakao, :templates, template_type),
          pf_id: pf_id.presence || config.dig(:kakao, :pf_id)
        )
      end
    end

    def initialize(invoice:, tenant:, template_type: :invoice_notice, template_id:, pf_id:)
      @invoice = invoice
      @tenant = tenant
      @template_type = template_type.to_sym
      @template_id = template_id
      @pf_id = pf_id
    end

    def to_message(to:)
      hash = { to: to, text: fallback_text }
      hash[:subject] = fallback_subject if lms?
      hash[:kakao_options] = { pf_id: @pf_id, template_id: @template_id, variables: variables }
      hash
    end

    def fallback_text
      @fallback_text ||=
        if reminder?
          reminder_text
        else
          I18n.t("messages.invoice_notice.sms_text", **i18n_args).strip
        end
    end

    def lms?
      fallback_text.bytesize > SMS_MAX_BYTES
    end

    # F6 미리보기(원장 화면)용 — 최종 본문 반환
    def preview_text
      fallback_text
    end

    def reminder?
      @template_type.in?(MessageLog::REMINDER_TEMPLATE_TYPES)
    end

    private

    def reminder_stage
      @template_type.to_s.delete_prefix("reminder_").to_sym # :d3 / :d7 / :month_end
    end

    # 커스텀 문구 우선(%{변수} 수동 보간 — I18n ASCII 키 제약 회피), 없으면 톤 기본 템플릿
    def reminder_text
      custom = @tenant.remind_custom_text(reminder_stage)
      return interpolate_custom(custom) if custom.present?

      I18n.t("messages.reminder.text.#{reminder_stage}.#{@tenant.remind_tone}", **i18n_args).strip
    end

    def interpolate_custom(custom)
      custom.gsub(/%\{(\w+)\}/) { variables.fetch(map_custom_key(Regexp.last_match(1)), "") }
    end

    # 커스텀 문구 변수(student_name 등 ASCII) → 카카오 템플릿 변수(한글) 매핑
    def map_custom_key(key)
      {
        "student_name" => "원생명", "month" => "청구월", "amount" => "금액",
        "account" => "계좌", "due" => "기한", "academy_name" => "원장상호",
        "owner_phone" => "원장전화"
      }.fetch(key, key)
    end

    def i18n_args
      {
        student_name: variables["원생명"], month: variables["청구월"],
        amount: variables["금액"], account: variables["계좌"],
        due: variables["기한"], academy_name: variables["원장상호"],
        owner_phone: variables["원장전화"]
      }
    end

    def fallback_subject
      return I18n.t("messages.reminder.sms_subject.#{reminder_stage}") if reminder?

      I18n.t("messages.invoice_notice.sms_subject")
    end

    # 카카오 템플릿 #{변수} 치환값 — PRD F3 본문 구성 요소.
    # 값 키는 카카오 템플릿 변수(운영 주입 템플릿과 매핑), SMS 폴백은 I18n(ASCII 키)과 매핑.
    def variables
      @variables ||= {
        "원생명" => @invoice.student_name_snapshot, # TEN-004 스냅샷
        "청구월" => month_label,
        "금액" => number_to_krw(@invoice.total_amount),
        "계좌" => bank_line,
        "기한" => due_label,
        "원장상호" => @tenant.name.to_s,
        "원장전화" => tenant_owner_phone
      }
    end

    def month_label
      I18n.t("messages.month_name", month: Date.parse("#{@invoice.target_month}-01").strftime("%-m"))
    end

    def bank_line
      return "" if @tenant.bank_name.blank?

      line = +"#{@tenant.bank_name} #{@tenant.bank_account}"
      line += " (예금주: #{@tenant.account_holder})" if @tenant.account_holder.present?
      line
    end

    def due_label
      return "" if @invoice.due_on.blank?

      I18n.t("messages.due_date", date: @invoice.due_on.strftime("%-m월 %-d일"))
    end

    # 원장전화: 계정 소유자(원장) 휴대폰번호 — 본문에만 사용(화면 표시는 masked_phone, TEN-003)
    def tenant_owner_phone
      @tenant.users.order(:id).pick(:phone_number).to_s
    end

    def number_to_krw(amount)
      "#{ActiveSupport::NumberHelper.number_to_delimited(amount.to_i)}원"
    end
  end
end

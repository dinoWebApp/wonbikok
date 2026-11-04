class BetaApplicationsController < ApplicationController
  # 베타(파일럿) 신청 — 랜딩 공개 폼(PRD 13.6) — 인증 게이트·온보딩 게이트 제외
  skip_before_action :require_authentication
  skip_before_action :ensure_onboarding_complete

  layout "landing"

  # 스팸 최소 방어(13.6) — 동일 IP 과도 제출 차단. CAPTCHA 등 강화는 과투자로 하지 않음(플랜 §1-A)
  rate_limit to: 10, within: 1.hour, only: :create, with: :rate_limited

  def new
    @beta_application = BetaApplication.new
  end

  def create
    @beta_application = BetaApplication.new(beta_application_params)

    if @beta_application.valid? && duplicate_submission?
      # 중복 신청 최소 식별(13.6) — 같은 연락처 신청이 있으면 새 레코드 없이
      # 동일한 완료 화면으로 안내("이미 신청하셨습니다" 노출 금지)
      redirect_to done_beta_applications_path, status: :see_other
    elsif save_idempotently
      redirect_to done_beta_applications_path, status: :see_other,
                  notice: t("beta_applications.notices.created")
    else
      # 랜딩 임베드 폼 — 오류를 유지한 채 랜딩 전체 재렌더(Turbo 규약 422)
      render "landing/show", status: :unprocessable_entity
    end
  end

  def done
  end

  private

  def beta_application_params
    params.expect(beta_application: [ :name, :title, :contact_type, :contact_value,
                                      :academy_type, :student_count_range, :current_method,
                                      :pain_point, :terms_agreed, :marketing_agreed ])
  end

  def duplicate_submission?
    BetaApplication.with_contact(@beta_application.contact_type, @beta_application.contact_value).exists?
  end

  # 동시 제출 경쟁 조건 방어 — exists? 조회 통과 후 save 사이 경합은
  # [contact_type, contact_value] 유니크 인덱스(TEN-003 준용)로 차단되며,
  # 여기서도 완료 화면 303으로 멱등 종결한다("이미 신청" 노출 없음 유지)
  def save_idempotently
    @beta_application.save
  rescue ActiveRecord::RecordNotUnique
    true
  end

  def rate_limited
    redirect_to root_path, status: :see_other, alert: t("beta_applications.notices.rate_limited")
  end
end

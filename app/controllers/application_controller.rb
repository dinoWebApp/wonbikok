class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  include Authentication

  helper_method :practice_mode?
  helper PhoneHelper

  # 온보딩 미완료 테넌트는 메인 기능(원생·청구·리마인더 등) 직접 접근 차단(W1 후속) —
  # 미완료 스텝으로 리다이렉트(이탈 재개). 세션·가입·온보딩 컨트롤러는 skip.
  before_action :ensure_onboarding_complete

  private

  def practice_mode?
    current_tenant&.practice?
  end

  def ensure_onboarding_complete
    return if current_tenant.onboarding_complete?

    redirect_to onboarding_step_path(onboarding_resume_step)
  end

  # 가입 직후(step=1) 이탈자 재개용 최소 스텝 보정(CRITICAL-2):
  # step 1은 실제 폼 스텝이 아니므로 첫 폼 스텝(STEPS.first=2)으로 클램프한다.
  def onboarding_resume_step
    [ current_tenant.onboarding_step, OnboardingController::STEPS.first ].max
  end
end

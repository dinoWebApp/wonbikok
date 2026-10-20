class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  include Authentication

  helper_method :practice_mode?
  helper PhoneHelper

  private

  def practice_mode?
    current_tenant&.practice?
  end

  # 온보딩 미완료 시 미완료 스텝으로 이동(이탈 재개)
  def redirect_if_onboarding_incomplete
    return false if current_tenant.onboarding_complete?

    redirect_to onboarding_step_path(
      [ current_tenant.onboarding_step, OnboardingController::STEPS.first ].max
    )
    true
  end
end

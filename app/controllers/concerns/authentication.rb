module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :current_user, :current_tenant, :authenticated?
  end

  private

  def authenticated?
    resume_session.present?
  end

  def current_user
    Current.user
  end

  def current_tenant
    Current.tenant
  end

  def require_authentication
    resume_session || redirect_to_login
  end

  def resume_session
    Current.user ||= session_record&.user.tap { |user| Current.tenant = user.tenant if user }
  end

  def session_record
    return @session_record if defined?(@session_record)

    if (sid = cookies.signed[:session_id])
      @session_record = Session.find_by(id: sid)
    end
  end

  def redirect_to_login
    clear_session
    redirect_to new_session_path, alert: t("auth.login_required")
  end

  def start_new_session_for(user)
    user.sessions.create!(ip_address: request.remote_ip, user_agent: request.user_agent).tap do |record|
      cookies.signed.permanent[:session_id] = { value: record.id, httponly: true }
    end
    resume_session
  end

  def clear_session
    cookies.delete(:session_id)
    session_record&.destroy
    @session_record = nil
    Current.reset
  end
end

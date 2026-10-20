class RegistrationsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create]

  def new
    @user = User.new
    @tenant = Tenant.new
  end

  # 가입 시 Tenant + User 동시 생성(트랜잭션). 온보딩 1스텝 완료 → 2스텝부터 진행.
  def create
    @tenant = Tenant.new(name: tenant_params[:name], onboarding_step: 1)
    @user = @tenant.users.build(user_params)

    if @user.invalid? || @tenant.invalid?
      flash.now[:alert] = t("errors.form")
      render :new, status: :unprocessable_entity
      return
    end

    Tenant.transaction do
      @tenant.save!
      @user.save!
    end
    start_new_session_for(@user)
    redirect_to onboarding_step_path(2), status: :see_other, notice: t("registration.completed")
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("errors.form")
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    # 동시 가입 레이스(WARNING-6): DB 유니크 인덱스 위반을 명확한 안내로 응답
    flash.now[:alert] = t("registration.duplicate_phone")
    render :new, status: :unprocessable_entity
  end

  private

  def user_params
    params.expect(user: [ :phone_number, :password, :password_confirmation ])
  end

  def tenant_params
    params.expect(tenant: [ :name ])
  end
end

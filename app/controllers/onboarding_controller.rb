class OnboardingController < ApplicationController
  STEPS = [ 2, 3, 4, 5 ].freeze

  # 온보딩 화면 자체는 게이트 제외(게이트가 온보딩으로 리다이렉트하는 대상이므로 — W1 후속)
  skip_before_action :ensure_onboarding_complete

  before_action :skip_if_onboarding_complete
  before_action :restrict_step_range

  def show
    @tenant = current_tenant
    render "step#{@step}"
  end

  def update
    @tenant = current_tenant

    case @step
    when 2 then save_business_info
    when 3 then save_bank_account
    when 5 then start_practice_or_real
    else advance_step(@step)
    end
  end

  private

  def step_param
    step = params[:step].to_i
    raise ActionController::BadRequest unless STEPS.include?(step)

    step
  end

  # 온보딩 스텝 우회 방지(WARNING-1): 현재 진행 스텝보다 1단계 초과 스텝은
  # 접근할 수 없다 — 현재 스텝으로 되돌린다.
  def restrict_step_range
    @step = step_param
    allowed_max = [ current_tenant.onboarding_step + 1, STEPS.max ].min
    return if @step <= allowed_max

    redirect_to onboarding_step_path(allowed_max)
  end

  def save_business_info
    @tenant.assign_attributes(business_params)
    unless @tenant.valid?(:business_info)
      flash.now[:alert] = t("errors.form")
      return render :step2, status: :unprocessable_entity
    end

    if @tenant.save
      advance_step(2)
    else
      flash.now[:alert] = t("errors.form")
      render :step2, status: :unprocessable_entity
    end
  end

  def save_bank_account
    @tenant.assign_attributes(bank_params)
    unless @tenant.valid?(:bank_info) # W1 후속: 계좌 3필드 서버측 presence(step2와 동일 패턴)
      flash.now[:alert] = t("errors.form")
      return render :step3, status: :unprocessable_entity
    end

    if @tenant.save
      advance_step(3)
    else
      flash.now[:alert] = t("errors.form")
      render :step3, status: :unprocessable_entity
    end
  end

  # 5스텝: 연습 모드 선택/시작 → 온보딩 완료 → 대시보드
  def start_practice_or_real
    if params[:commit] == "practice"
      @tenant.update!(practice: true)
      PracticeDataSeeder.new(tenant: @tenant).call
    end
    @tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
    redirect_to root_path, status: :see_other, notice: t("onboarding.completed")
  end

  def advance_step(from)
    # 같은 스텝 재제출로 진행 스텝이 되돌아가지 않도록 상향만 허용
    @tenant.update!(onboarding_step: [ @tenant.onboarding_step, from + 1 ].max)
    redirect_to onboarding_step_path(@tenant.onboarding_step), status: :see_other
  end

  def skip_if_onboarding_complete
    redirect_to root_path if current_tenant.onboarding_complete?
  end

  def business_params
    params.expect(tenant: [ :name, :business_number, :business_type, :owner_name, :address ])
  end

  def bank_params
    params.expect(tenant: [ :bank_name, :bank_account, :account_holder ])
  end
end

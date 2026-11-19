class RegistrationsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create send_verification verify_code]
  # 가입 자체는 온보딩 이전 단계 — 게이트 제외(W1 후속)
  skip_before_action :ensure_onboarding_complete

  # 가입 대입·인증번호 남용 완화(F10 REF-006 — 서비스 레이트 리밋 1분 1회와 이중 방어)
  rate_limit to: 10, within: 3.minutes, only: %i[send_verification verify_code]

  # REF-006: 가입 제출 시 검증 완료 레코드가 없는 경우 — 가입 트랜잭션 롤백 후 422 안내
  VerificationMissingError = Class.new(StandardError)

  def new
    @user = User.new
    @tenant = Tenant.new
  end

  # 인증번호 발송(Stimulus fetch — JSON 응답). 서비스가 레이트 리밋(1분 1회)·정규화·코드 해시 저장 담당.
  def send_verification
    result = Signup::PhoneVerificationService.send_code!(params[:phone_number])

    if result.ok?
      render json: { status: "ok", message: t("signup_verification.sent_notice") }
    else
      render json: { status: "error", message: t("signup_verification.errors.#{result.reason}") },
             status: result.reason == :rate_limited ? :too_many_requests : :unprocessable_entity
    end
  end

  # 인증번호 확인(Stimulus fetch — JSON 응답). 검증 상태는 DB(signup_verifications) 기준.
  def verify_code
    result = Signup::PhoneVerificationService.verify!(params[:phone_number], params[:code])

    if result.ok?
      render json: { status: "ok", message: t("signup_verification.verified_notice") }
    else
      render json: { status: "error", message: t("signup_verification.errors.#{result.reason}") },
             status: :unprocessable_entity
    end
  end

  # 가입 시 Tenant + User 동시 생성(트랜잭션). 온보딩 1스텝 완료 → 2스텝부터 진행.
  #
  # F10 서버 검증(REF-006·REF-001 — UI 인증은 보조일 뿐, 원천은 signup_verifications):
  # - 제출 전화번호 = 검증 완료(verified·미소비·미만료) 전화번호 + 소비(consume!) 필수 — 아니면 422.
  #   소비는 가입 트랜잭션 내부에서 수행 — 가입 실패 시 소비도 함께 롤백된다.
  # - 추천 코드(선택): 유효 코드만 수용 — 무효 코드는 422 안내. 유효 시 tenants 매핑·코드 스냅샷 저장.
  def create
    @tenant = Tenant.new(name: tenant_params[:name], onboarding_step: 1)
    @user = @tenant.users.build(user_params)

    if @user.invalid? || @tenant.invalid?
      flash.now[:alert] = t("errors.form")
      render :new, status: :unprocessable_entity
      return
    end

    apply_referral_code!(@tenant) # REF-001 — 유효 코드만 수용(무효는 422)
    return if performed?

    Tenant.transaction do
      @tenant.save!
      @user.save!
      raise VerificationMissingError unless consume_phone_verification!
      # F8: 30일 무료체험 자동 시작(멱등 — TrialService). 실패해도 가입은 차단하지 않는다(로그만).
      begin
        Subscriptions::TrialService.start_for!(@tenant)
      rescue StandardError => e
        Rails.logger.warn("[Registrations] trial start skipped tenant=#{@tenant.id} " \
                          "error=#{e.class}: #{e.message}")
      end
    end
    start_new_session_for(@user)
    redirect_to onboarding_step_path(2), status: :see_other, notice: t("registration.completed")
  rescue VerificationMissingError
    flash.now[:alert] = t("signup_verification.errors.required")
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("errors.form")
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    # 동시 가입 레이스(WARNING-6): DB 유니크 인덱스 위반을 명확한 안내로 응답
    flash.now[:alert] = t("registration.duplicate_phone")
    render :new, status: :unprocessable_entity
  end

  private

  # REF-006: 검증 완료 레코드 소비(원자 — 동시 가입 레이스에서 1회만 소비).
  def consume_phone_verification!
    Signup::PhoneVerificationService.consume!(@user.phone_number).present?
  end

  # REF-001: 추천 코드 유효성 검증 — 유효 시 직원 매핑+코드 스냅샷(가입 시점 — 이후 로테이션 무영향),
  # 입력이 있고 무효면 422 안내. 입력 없음은 추천 없는 가입(정상 경로).
  def apply_referral_code!(tenant)
    code = params[:referral_code].to_s.strip.upcase.presence
    return if code.nil?

    sales_rep = Referral::CodeService.verify!(code)
    if sales_rep.nil?
      flash.now[:alert] = t("signup_verification.errors.referral_invalid")
      render :new, status: :unprocessable_entity
      return
    end

    tenant.referred_by_sales_rep = sales_rep
    tenant.referral_code_snapshot = code
  end

  def user_params
    params.expect(user: [ :phone_number, :password, :password_confirmation ])
  end

  def tenant_params
    params.expect(tenant: [ :name ])
  end
end

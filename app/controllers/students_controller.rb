# 원생 관리 컨트롤러 (W1 F2).
# 모든 조회는 current_tenant 스코프 경유(TEN-001). 전화번호는 masked_phone으로만
# 표시(TEN-003). 청구·발행 이력은 W2 이후 제공 — 현재는 빈 상태 안내.
# 플랜 원생 수 상한 초과 체크(SUB-001)는 W4 구현 예정 — 이 컨트롤러에는 미반영.
class StudentsController < ApplicationController
  MAX_IMPORT_FILE_BYTES = 1.megabyte

  before_action :set_student, only: %i[show edit update pause withdraw restore]

  def index
    @students = filtered_students.order(:id)
    @sibling_student_ids = GuardianDuplicateFinder.new(current_tenant).sibling_student_ids
  end

  def show
    @sibling_students = sibling_students_of(@student)
  end

  def new
    @student = current_tenant.students.build
    @student.guardians.build
  end

  def create
    @student = current_tenant.students.build(student_params)

    # 저장 전 유사 이름·연락처 중복 확인(형제 등록 허용, 확인 절차만 수행)
    unless duplicates_confirmed?
      @conflicts = find_conflicts
      render :new, status: :unprocessable_entity and return if @conflicts.any?
    end

    if @student.save
      redirect_to students_path, status: :see_other,
                                 notice: t("students.notices.created", name: @student.name)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @student.update(student_params)
      redirect_to student_path(@student), status: :see_other,
                                          notice: t("students.notices.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # 상태 변경: 재원→휴원/퇴원 시 ended_on 기록, 복원 시 해제(모델 콜백)
  def pause
    transition_to!(:paused)
  end

  def withdraw
    transition_to!(:withdrawn)
  end

  def restore
    transition_to!(:active)
  end

  # == CSV 일괄 등록 ==
  def import_new
  end

  def import
    upload = params[:file]
    if upload.blank? || !upload.respond_to?(:read)
      flash.now[:alert] = t("students.import.errors.no_file")
      return render :import_new, status: :unprocessable_entity
    end
    if upload.size > MAX_IMPORT_FILE_BYTES
      flash.now[:alert] = t("students.import.errors.file_too_large")
      return render :import_new, status: :unprocessable_entity
    end

    @result = StudentsCsvImportService.new(tenant: current_tenant, upload: upload).call
    store_import_errors(@result.errors)
    if @result.errors.any?
      render :import_result, status: :unprocessable_entity
    else
      render :import_result
    end
  end

  # 양식 다운로드(예시 데이터만 포함, UTF-8 BOM)
  def import_template
    send_data StudentsCsvTemplateService.with_bom(StudentsCsvTemplateService.template_csv),
              filename: "students_template.csv", type: "text/csv; charset=utf-8"
  end

  # 오류행만 담은 CSV 재내려받기 → 같은 양식으로 2차 업로드
  def import_errors
    key = session[:csv_import_errors_key].to_s
    stored = key.present? ? Rails.cache.read(key) : nil
    if stored.blank?
      redirect_to import_students_path, alert: t("students.import.errors.expired")
      return
    end

    rows = stored.map do |error|
      StudentsCsvImportService::ImportError.new(line: error["line"],
                                                row_values: error["row_values"],
                                                reasons: error["reasons"])
    end
    send_data StudentsCsvTemplateService.with_bom(StudentsCsvTemplateService.error_csv(rows)),
              filename: "students_errors.csv", type: "text/csv; charset=utf-8"
  end

  private

  # 오류내역은 쿠키 세션(CookieStore 4KB 한도)이 아닌 서버측 캐시에 저장(BLOCKER-1).
  # 세션에는 조회용 키만 두고, 내역은 30분 후 만료 — 만료 시 재업로드 안내.
  def store_import_errors(errors)
    key = "csv_import_errors:#{current_tenant.id}:#{SecureRandom.urlsafe_base64(16)}"
    Rails.cache.write(key,
                      errors.map { |e| { "line" => e.line, "row_values" => e.row_values, "reasons" => e.reasons } },
                      expires_in: 30.minutes)
    session[:csv_import_errors_key] = key
  end

  def set_student
    @student = current_tenant.students.includes(:guardians).find(params[:id]) # TEN-001
  end

  def filtered_students
    scope = current_tenant.students.includes(:guardians)
    if (q = params[:q]).is_a?(String) && q.strip.present?
      scope = scope.where("name LIKE ?", "%#{q.strip}%")
    end
    if params[:phone_last4].present? && params[:phone_last4].match?(/\A\d{4}\z/)
      scope = scope.joins(:guardians).where(guardians: { phone_last4: params[:phone_last4] }).distinct
    end
    scope = scope.where(status: params[:status]) if params[:status].in?(Student.statuses.keys)
    scope
  end

  def transition_to!(new_status)
    @student.update!(status: new_status)
    redirect_to student_path(@student), status: :see_other,
                                        notice: t("students.notices.status_changed",
                                                  status: Student.human_attribute_name("status/#{new_status}"))
  end

  def duplicates_confirmed?
    params[:confirm] == "1"
  end

  def find_conflicts
    guardian = Array(student_params[:guardians_attributes]).first || {}
    GuardianDuplicateFinder.new(current_tenant).conflicts_with(
      name: student_params[:name], phone_number: guardian[:phone_number].to_s
    )
  end

  # 동일 보호자 전화를 공유하는 형제 원생(자기 자신 제외)
  def sibling_students_of(student)
    GuardianDuplicateFinder.new(current_tenant).sibling_groups
                           .flatten.select { |s| s.id != student.id }
  end

  def student_params
    params.expect(student: [
      :name, :grade, :monthly_fee, :payment_day, :payment_type, :memo, :status, :started_on,
      { guardians_attributes: [ [ :id, :name, :phone_number ] ] }
    ])
  end
end

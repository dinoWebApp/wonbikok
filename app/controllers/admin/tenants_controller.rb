# 이용자(원장) 관리 (PRD 12장 A2 — 문의 전화 30초 안에 상황 파악).
#
# - index: 통합 검색(Admin::TenantSearchService — 상호·사업자번호·ID, v1.0 전화 검색 축소).
# - show: 기본 정보(ADM-002 마스킹)·플랜·체험 잔여일·원생 수·마지막 활동·월간 요약·이벤트 타임라인.
# - A0: 이용자 상세 열람 자체를 개인정보 접근 로그(audit personal_info_viewed)로 기록.
#   단, 기본 마스킹 상태의 열람만으로는 로그를 남기지 않고, 개인정보가 포함된 상세 열람 시 기록한다
#   (본 화면은 항상 마스킹 표시이므로 "마스킹된 상세 열람" 기록 — 과잉 로그 방지).
class Admin::TenantsController < Admin::BaseController
  INDEX_LIMIT = 100

  # index 행 — 뷰 쿼리 금지: 마스킹·플랜 표시에 필요한 값을 컨트롤러에서 완성해 주입.
  IndexRow = Data.define(:tenant, :masked_business_number, :masked_owner_name, :masked_owner_phone,
                         :subscription, :students_count)

  def index
    tenants = Admin::TenantSearchService.new.call(params[:q]).limit(INDEX_LIMIT)
    subscriptions_by_tenant = subscription_index_by_tenant(tenants.map(&:id))
    students_count_by_tenant = Student.where(tenant_id: tenants.map(&:id)).group(:tenant_id).count
    owners_by_tenant = User.where(tenant_id: tenants.map(&:id)).order(:id).group_by(&:tenant_id)

    @rows = tenants.map do |tenant|
      owner = owners_by_tenant[tenant.id]&.first
      IndexRow.new(tenant: tenant,
                   masked_business_number: admin_mask_business_number(tenant.business_number),
                   masked_owner_name: admin_mask_name(tenant.owner_name),
                   masked_owner_phone: admin_mask_phone(owner&.phone_number),
                   subscription: subscriptions_by_tenant[tenant.id],
                   students_count: students_count_by_tenant[tenant.id].to_i)
    end
    @query = params[:q].to_s.strip
  end

  def show
    prepare_tenant_show!(Tenant.find(params[:id]))
    AuditLog.record!(admin_user: current_admin_user, action: "personal_info_viewed",
                     target: @tenant, detail: { display: "masked" }) # A0 개인정보 접근 로그
  end

  private

  # [3-S 결합 지점] Subscription(tenant_id 유니크, 01_plan §2) — 미병합 환경 폴백 포함.
  def subscription_index_by_tenant(tenant_ids)
    Subscription.where(tenant_id: tenant_ids).index_by(&:tenant_id)
  rescue NameError, ActiveRecord::StatementInvalid
    {}
  end
end

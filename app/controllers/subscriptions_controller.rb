# 구독·결제 (W4 F8 v1.0 최소형 — 단일 리소스 show, 원장 화면).
# v1.0은 현황 표시·안내 중심(PRD 7장 F8): 플랜 변경·수동 결제 등록 실행은 관리자 A2·A3 경유이며,
# 이 화면은 상태 배너(SUB-002/003/004 앱 배너 축)·상한·이력·안내를 제공한다.
# TEN-001: 조회는 current_tenant 스코프 경유만 — 타 테넌트 구독은 애초에 조회 대상이 아니다.
class SubscriptionsController < ApplicationController
  RECENT_EVENTS_LIMIT = 20

  def show
    @subscription = Subscription.find_by(tenant_id: current_tenant.id)
    # 레거시 계정(W4 이전 가입·체험 서비스 미적용) — 구독 없음을 안내하는 빈 화면
    return render :empty, status: :ok if @subscription.nil?

    @students_count = current_tenant.students.active.count # SUB-001 집계 기준: 재원 원생
    @recent_events = @subscription.subscription_events
                                  .order(created_at: :desc, id: :desc)
                                  .limit(RECENT_EVENTS_LIMIT)
    @pending_downgrade = @subscription.pending_downgrade
    @retention_deadline = Subscriptions::RetryPolicyService.data_retention_deadline(@subscription)
    @retention_remaining = Subscriptions::RetryPolicyService.remaining_retention_days(@subscription)
  end
end

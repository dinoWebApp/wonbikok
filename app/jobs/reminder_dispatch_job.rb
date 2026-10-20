# 매일 리마인더 디스패치 배치 (F6 — config/recurring.yml, 매일 09:00 / MSG-006).
# Reminders::Scheduler에 위임 — 대상 판정·단계 템플릿·제외 배제·MSG-006 발송 시각.
class ReminderDispatchJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::Scheduler.new(date: Date.current).dispatch_all
  end
end

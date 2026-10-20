module StudentsHelper
  # 상태 색상 배지 (TEN-003: 전화번호는 masked_phone으로만 표시)
  def status_badge_class(status)
    case status
    when "active" then "bg-emerald-100 text-emerald-800"
    when "paused" then "bg-amber-100 text-amber-800"
    else "bg-slate-200 text-slate-600"
    end
  end
end

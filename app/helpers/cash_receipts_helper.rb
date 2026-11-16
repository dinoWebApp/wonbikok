module CashReceiptsHelper
  # CR 상태 배지 톤 — PRD 16.2 배지 체계(색+텍스트 병행)
  # issued=success / processing·pending=info·중립 / failed=danger / needs_info=warning / cancelled=neutral
  def state_badge_tone(receipt)
    case receipt.state
    when "issued" then :success
    when "processing" then :info
    when "pending", "cancel_pending" then :neutral
    when "failed" then :danger
    when "needs_info" then :warning
    else :neutral
    end
  end
end

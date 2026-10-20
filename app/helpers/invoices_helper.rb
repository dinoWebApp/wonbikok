module InvoicesHelper
  def invoice_status_badge_class(status)
    base = "ml-2 inline-block rounded-full px-2 py-0.5 text-xs font-semibold align-middle "
    case status
    when "DRAFT" then base + "bg-slate-100 text-slate-600"
    when "READY" then base + "bg-blue-100 text-blue-700"
    when "SENT" then base + "bg-emerald-100 text-emerald-700"
    when "UNPAID", "OVERDUE" then base + "bg-amber-100 text-amber-700"
    when "CANCELLED" then base + "bg-red-100 text-red-600 line-through"
    else base + "bg-slate-100 text-slate-600"
    end
  end

  def message_status_badge_class(status)
    base = "inline-block rounded-full px-2 py-0.5 text-xs font-semibold "
    case status
    when "QUEUED" then base + "bg-blue-100 text-blue-700"
    when "SENDING" then base + "bg-slate-100 text-slate-600"
    when "SENT" then base + "bg-emerald-100 text-emerald-700"
    when "FALLBACK_SENT" then base + "bg-teal-100 text-teal-700"
    when "SIMULATED" then base + "bg-violet-100 text-violet-700"
    when "FAILED" then base + "bg-red-100 text-red-600"
    else base + "bg-slate-100 text-slate-600"
    end
  end

  def prev_month(month)
    Date.parse("#{month}-01").prev_month.strftime("%Y-%m")
  end

  def next_month(month)
    Date.parse("#{month}-01").next_month.strftime("%Y-%m")
  end
end

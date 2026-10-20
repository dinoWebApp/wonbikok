import { Controller } from "@hotwired/stimulus"

// 미납 리마인더 목록 전체 선택 (F6 즉시 발송)
export default class extends Controller {
  toggle(event) {
    this.element
      .closest("form")
      .querySelectorAll('input[name="invoice_ids[]"]')
      .forEach((checkbox) => { checkbox.checked = event.target.checked })
  }
}

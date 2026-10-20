# F6: 리마인더 단계별 원장 커스텀 문구 저장(기본 템플릿 3종[부드러움/표준/공식]보다 우선 적용).
# 단계(d3/d7/month_end)별 1개 컬럼 — 최소 범위.
class AddReminderCustomTexts < ActiveRecord::Migration[8.1]
  def change
    change_table :tenants do |t|
      t.text :remind_custom_text_d3
      t.text :remind_custom_text_d7
      t.text :remind_custom_text_month_end
    end
  end
end

class CreateStudents < ActiveRecord::Migration[8.1]
  def change
    create_table :students do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :name, null: false
      t.string :grade
      t.integer :monthly_fee, default: 0, null: false
      t.integer :payment_day, default: 25, null: false
      t.string :payment_type, default: "계좌이체", null: false
      t.text :memo
      t.string :status, default: "active", null: false
      t.date :started_on
      t.date :ended_on

      t.timestamps
    end
    add_index :students, [ :tenant_id, :status ]
  end
end

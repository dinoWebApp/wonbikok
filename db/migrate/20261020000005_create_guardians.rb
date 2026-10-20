class CreateGuardians < ActiveRecord::Migration[8.1]
  def change
    create_table :guardians do |t|
      t.references :student, null: false, foreign_key: true
      t.string :name, null: false
      t.string :phone_number, null: false
      t.string :phone_last4, null: false
      t.boolean :is_primary, default: true, null: false

      t.timestamps
    end
    add_index :guardians, :phone_last4
  end
end

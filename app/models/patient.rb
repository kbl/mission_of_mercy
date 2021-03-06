class Patient < ActiveRecord::Base
  REGEXP = {
    :time_in_pain   => /\A(\d*\.?\d*)\s*(.+)\Z/,
    :number_only    => /\A(\d*\.?\d*)\Z/,
    :days           => /\Ad(ay(s)?)?\Z/i,
    :weeks          => /\Aw(eek(s)?)?\Z/i,
    :months         => /\Am(onth(s)?)?\Z/i,
    :years          => /\Ay(ear(s)?)?\Z/i
  }

  REGEXP[:all_time_units] = Regexp.union( REGEXP[:days],
                                          REGEXP[:weeks],
                                          REGEXP[:months],
                                          REGEXP[:years] )

  before_save  :update_survey
  before_save  :normalize_data
  after_create :check_in_flow

  has_many :patient_prescriptions, :dependent   => :delete_all
  has_many :patient_procedures,    :dependent   => :delete_all
  has_many :patient_pre_meds,      :dependent   => :delete_all
  has_many :procedures,            :through     => :patient_procedures
  has_many :prescriptions,         :through     => :patient_prescriptions
  has_many :pre_meds,              :through     => :patient_pre_meds
  has_many :flows,                 :class_name  => "PatientFlow",
                                   :dependent   => :delete_all
  has_many :previous_mom_clinics,  :class_name  => "PatientPreviousMomClinic",
                                   :dependent   => :delete_all

  has_one :prosthetic,             :dependent   => :delete
  has_one :zipcode,                :class_name  => "Patient::Zipcode",
                                   :foreign_key => "zip",
                                   :primary_key => "zip"

  belongs_to :survey,              :dependent  => :delete
  belongs_to :assigned_treatment_area, :class_name => "TreatmentArea"

  accepts_nested_attributes_for :survey
  accepts_nested_attributes_for :prosthetic
  accepts_nested_attributes_for :patient_prescriptions, :allow_destroy => true,
                                :reject_if => proc { |attributes| attributes['prescribed'] == "0" }

  accepts_nested_attributes_for :patient_pre_meds, :allow_destroy => true,
                                :reject_if => proc { |attributes| attributes['prescribed'] == "0" }

  accepts_nested_attributes_for :previous_mom_clinics, :allow_destroy => true,
                                :reject_if => proc { |attributes| attributes['attended'] == "0" }

  validate              :time_in_pain_format
  validate              :date_of_birth_entry
  validates_length_of   :zip,   :maximum => 10, :allow_blank => true
  validates_length_of   :state, :maximum => 2
  validates_presence_of :first_name, :last_name, :sex, :race,
                        :chief_complaint, :last_dental_visit, :travel_time,
                        :city, :state
  validates_format_of   :phone, :message     => "must be a valid telephone number.",
                                :with        => /^[\(\)0-9\- \+\.]{10,20}$/,
                                :allow_blank => true
  validates_numericality_of :travel_time, :greater_than => 0
  attr_accessor :race_other
  attr_reader   :time_in_pain

  # Old Pagination Method ...
  def self.search(chart_number, name, page)
    conditions = if chart_number.blank? && !name.blank?
      ['first_name ILIKE ? or last_name ILIKE ?', "%#{name}%","%#{name}%"]
    elsif !chart_number.blank? && chart_number.to_i != 0
      ["id = ?", chart_number]
    else
      ["id = ?", -1]
    end

		Patient.where(conditions).order('id').paginate(:per_page => 30, :page => page)
	end

  def chart_number
    id
  end

  def full_name
    [first_name,last_name].join(' ')
  end

  def age
    today = DateTime.now
    age = today - date_of_birth
    age.to_i / 365
  rescue
    nil
  end

  def dob
    date_of_birth.strftime("%m/%d/%Y") if date_of_birth
  end

  def date_of_birth_dexis
    date_of_birth.strftime("%d.%m.%Y") if date_of_birth
  end

  def procedures_grouped
    patient_procedures.group_by(&:procedure)
  end

  def check_out(area)
    unless area == TreatmentArea.radiology
      self.flows.create(:area_id => ClinicArea::CHECKOUT,
                        :treatment_area_id => area.id)

      self.update_attributes(:assigned_treatment_area_id => nil,
                             :survey_id                  => nil,
                             :radiology                  => false)
    end
  end

  def export_to_dexis(path)
    f = File.new(path, "w")
    f.write(["PN=", "#{Date.today.year}#{id}", "\r\n"].join())
    f.write(["LN=", last_name, "\r\n"].join())
    f.write(["FN=", first_name, "\r\n"].join())
    f.write(["BD=", date_of_birth_dexis, "\r\n"].join())
    f.write(["SX=", sex].join())
    f.close
  end

  def travel_time_hours=(hours)
    @travel_time_hours = hours.to_i

    calculate_travel_time
  end

  def travel_time_hours
    @travel_time_hours ||= 0
  end

  def travel_time_minutes=(minutes)
    @travel_time_minutes = minutes.to_i

    calculate_travel_time
  end

  def travel_time_minutes
    @travel_time_minutes ||= 0
  end

  def time_in_pain=(time_in_pain)
    @time_in_pain = time_in_pain.strip
    if match = REGEXP[:time_in_pain].match(@time_in_pain)
      number, units = match.captures
      units.downcase!

      units = case units
      when REGEXP[:days] then "days"
      when REGEXP[:weeks] then "weeks"
      when REGEXP[:months] then "months"
      when REGEXP[:years] then "years"
      else
        nil
      end

      # Use highest possible precision - Float if possible, otherwise Integer
      unless units.nil?
        if ["days", "weeks"].include?(units)
          self.pain_length_in_days = (number.to_f.send(units) / 1.day).round
        else
          self.pain_length_in_days = (number.to_i.send(units) / 1.day)
        end
      end
    elsif REGEXP[:number_only].match(@time_in_pain)
      self.pain_length_in_days = @time_in_pain.to_i
    end
  end

  def date_of_birth=(date_of_birth)
    if date_of_birth.is_a?(String)
      @date_string = date_of_birth
      self[:date_of_birth] = Date.strptime(date_of_birth.tr("-.", "/"), "%m/%d/%Y") rescue nil
    else
      super
    end
  end

  private

  def update_survey
    if self.survey
      self.survey.city                = city
      self.survey.state               = state
      self.survey.zip                 = zip
      self.survey.age                 = age
      self.survey.sex                 = sex
      self.survey.race                = race
      self.survey.pain                = pain
      self.survey.pain_length_in_days = pain_length_in_days
    end
  end

  def normalize_data
    self.race = race_other if race_other != nil and race == "Other"

    self.first_name.capitalize!
    self.last_name.capitalize!
  end

  def check_in_flow
    self.flows.create(:area_id => ClinicArea::CHECKIN)
  end

  def time_in_pain_format
    error_message = "must be in a valid format (1 day, 1w, 5 years)"

    unless @time_in_pain.blank?
      if match = REGEXP[:time_in_pain].match(@time_in_pain)
        number, units = match.captures
        if units =~ REGEXP[:all_time_units]
          return true
        end
      elsif @time_in_pain =~ REGEXP[:number_only]
        return true
      end

      errors.add(:time_in_pain, error_message)
      return false
    end
  end

  def calculate_travel_time
    self.travel_time = travel_time_minutes + (travel_time_hours * 60)
  end

  def date_of_birth_entry
    if self.date_of_birth.nil?
      if @date_string.blank?
        errors.add(:date_of_birth, "can't be blank")
      else
        errors.add(:date_of_birth, "must be in a valid format (mm/dd/yyyy, mm-dd-yyyy)")
      end
      return false
    end

    return true
  end
end
